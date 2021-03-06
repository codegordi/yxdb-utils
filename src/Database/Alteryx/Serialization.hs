{-# LANGUAGE OverloadedStrings,MultiParamTypeClasses #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}

module Database.Alteryx.Serialization
    (
      dbFileId,
      getRecord,
      getValue,
      putRecord,
      putValue,
      headerPageSize,
      miniblockThreshold,
      numMetadataBytesActual,
      numMetadataBytesHeader,
      numBlockBytesActual,
      numBlockBytesHeader,
      parseRecordsUntil,
      recordsPerBlock,
      startOfBlocksByteIndex
    ) where

import Database.Alteryx.Fields
import Database.Alteryx.Types

import Codec.Compression.LZF.ByteString (decompressByteStringFixed, compressByteStringFixed)
import qualified Control.Newtype as NT
import Control.Applicative
import Control.Lens
import Control.Monad as M
import Control.Monad.Loops
import Data.Array.IArray (listArray, bounds, elems)
import Data.Binary
import Data.Binary.C ()
import Data.Binary.Get
import Data.Binary.Put
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as BSL
import Data.Conduit
import Data.Conduit.List (sourceList)
import Data.Conduit.Lazy (lazyConsume)
import qualified Data.Map as Map
import Data.Maybe (isJust, listToMaybe)
import Data.Text as T
import Data.Text.Encoding
import qualified Data.Text.Lazy as TL
import Data.Time.Clock.POSIX
import System.IO.Unsafe (unsafePerformIO)
import Text.XML hiding (renderText)
import Text.XML.Cursor as XMLC
    (
     Cursor,
     ($//),
     attribute,
     element,
     fromDocument
    )
import Text.XML.Stream.Render (renderText)
import Text.XML.Unresolved (toEvents)

-- | Number of records before each block is flushed and added to the block index
recordsPerBlock :: Int
recordsPerBlock = 0x10000

spatialIndexRecordBlockSize = 32

-- | Number of bytes taken by the fixed header
headerPageSize :: Int
headerPageSize = 512

-- | When writing miniblocks, how many bytes should each miniblock aim for?
miniblockThreshold :: Int
miniblockThreshold = 0x10000

-- | When decompressing miniblocks, how many bytes should be allocated for the output?
bufferSize :: Int
bufferSize = 0x40000

dbFileId :: DbType -> Word32
dbFileId WrigleyDb = 0x00440205
dbFileId WrigleyDb_NoSpatialIndex = 0x00440204

numBytes :: (Binary b, Num t) => b -> t
numBytes x = fromIntegral $ BSL.length $ runPut $ put x

numMetadataBytesHeader :: Header -> Int
numMetadataBytesHeader header = fromIntegral $ 2 * (header ^. metaInfoLength)

numMetadataBytesActual :: RecordInfo -> Int
numMetadataBytesActual recordInfo = numBytes recordInfo

numBlockBytesHeader :: Header -> Int
numBlockBytesHeader header =
    let start = headerPageSize + (numMetadataBytesHeader header)
        end =  (fromIntegral $ header ^. recordBlockIndexPos)
    in end - start

numBlockBytesActual :: Block -> Int
numBlockBytesActual block = numBytes block

startOfBlocksByteIndex :: Header -> Int
startOfBlocksByteIndex header =
    headerPageSize + (numMetadataBytesHeader header)

parseRecordsUntil :: RecordInfo -> Get [Record]
parseRecordsUntil recordInfo = do
  done <- isEmpty
  if done
    then return $ []
    else (:) <$> getRecord recordInfo <*> parseRecordsUntil recordInfo


-- | This binary instance is really slow because the YxdbFile type stores a list of records. Use the Conduit functions instead.
instance Binary YxdbFile where
    put yxdbFile = do
      put $ yxdbFile ^. yxdbFileHeader
      put $ yxdbFile ^. yxdbFileMetadata
      mapM_ (putRecord $ yxdbFile ^. yxdbFileMetadata) $ yxdbFile ^. yxdbFileRecords
      put $ yxdbFile ^. yxdbFileBlockIndex

    get = do
      fHeader     <- label "Header" $ isolate (fromIntegral headerPageSize) get
      fMetadata   <- label "Metadata" $ isolate (numMetadataBytesHeader fHeader) $ get

      let numBlockBytes = numBlockBytesHeader $ fHeader

      fBlocks    <- label ("Blocks of size " ++ show numBlockBytes) $
                    isolate numBlockBytes get :: Get Block
      fBlockIndex <- label "Block Index" get
      let fRecords = runGet (label "Records" $ parseRecordsUntil fMetadata) $ NT.unpack fBlocks

      return $ YxdbFile {
        _yxdbFileHeader     = fHeader,
        _yxdbFileMetadata   = fMetadata,
        _yxdbFileRecords    = fRecords,
        _yxdbFileBlockIndex = fBlockIndex
      }

documentToTextWithoutXMLHeader :: Document -> T.Text
documentToTextWithoutXMLHeader document =
  let events = Prelude.tail $ toEvents $ toXMLDocument document
  in T.concat $
     unsafePerformIO $
     lazyConsume $
     sourceList events $=
     renderText def

instance Binary RecordInfo where
    put metadata =
      let fieldMap :: Field -> Map.Map Name Text
          fieldMap field =
              let
                  requiredAttributes =
                      [
                       ("name", field ^. fieldName),
                       ("type", renderFieldType $ field ^. fieldType)
                      ]
                  sizeAttributes =
                      case field ^. fieldSize of
                        Nothing -> [ ]
                        Just x -> [ ("size", T.pack $ show x) ]
                  scaleAttributes =
                      case field ^. fieldScale of
                        Nothing -> [ ]
                        Just x -> [ ("scale", T.pack $ show x) ]
              in Map.fromList $
                 Prelude.concat $
                 [ requiredAttributes, sizeAttributes, scaleAttributes ]
          transformField field =
              NodeElement $
              Element "Field" (fieldMap field) [ ]
          transformRecordInfo recordInfo =
              NodeElement $
              Element "RecordInfo" Map.empty $
              Prelude.map transformField recordInfo
          transformMetaInfo (RecordInfo recordInfo) =
              Element "MetaInfo" Map.empty [ transformRecordInfo recordInfo]
          transformToDocument node = Document (Prologue [] Nothing []) node []

          renderMetaInfo metadata =
              encodeUtf16LE $
              flip T.snoc '\0' $
              flip T.snoc '\n' $
              documentToTextWithoutXMLHeader $
              transformToDocument $
              transformMetaInfo metadata
      in putByteString $ renderMetaInfo metadata

    get = do
      bs <- BS.concat . BSL.toChunks <$>
            getRemainingLazyByteString
      when (BS.length bs < 4) $ fail $ "No trailing newline and null: " ++ show bs
      let text = T.init $ T.init $ decodeUtf16LE bs
      let document = parseText_ def $ TL.fromStrict text
      let cursor = fromDocument document
      let recordInfos = parseXmlRecordInfo cursor
      case recordInfos of
        []   -> fail "No RecordInfo entries found"
        x:[] -> return x
        xs   -> fail "Too many RecordInfo entries found"

parseXmlField :: Cursor -> [Field]
parseXmlField cursor = do
  let fieldCursors = cursor $// XMLC.element "Field"
  fieldCursor <- fieldCursors

  aName <- attribute "name" fieldCursor
  aType <- attribute "type" fieldCursor

  let aDesc = listToMaybe $ attribute "description" fieldCursor
  let aSize = listToMaybe $ attribute "size" fieldCursor
  let aScale = listToMaybe $ attribute "scale" fieldCursor

  return $ Field {
               _fieldName  = aName,
               _fieldType  = parseFieldType aType,
               _fieldSize  = parseInt <$> aSize,
               _fieldScale = parseInt <$> aScale
             }

parseXmlRecordInfo :: Cursor -> [RecordInfo]
parseXmlRecordInfo cursor = do
  let recordInfoCursors = cursor $// XMLC.element "RecordInfo"
  recordInfoCursor <- recordInfoCursors
  let fields = parseXmlField recordInfoCursor
  return $ RecordInfo fields

parseInt :: Text -> Int
parseInt text = read $ T.unpack text :: Int

-- | True if any fields have associated variable data in the variable data portion of the record.
hasVariableData :: RecordInfo -> Bool
hasVariableData (RecordInfo recordInfo) =
  let fieldHasVariableData field =
          case field ^. fieldType of
            FTVString  -> True
            FTVWString -> True
            FTBlob     -> True
            _          -> False
  in Prelude.any fieldHasVariableData recordInfo

-- | Writes a record using the provided metadata.
putRecord :: RecordInfo -> Record -> Put
putRecord recordInfo@(RecordInfo fields) (Record fieldValues) = do
  zipWithM_ putValue fields fieldValues
  when (hasVariableData recordInfo) $ do
    error "putRecord: Variable data unimplemented"

-- | Records consists of a fixed amount of data for each field, and also a possibly large amoutn of variable data at the end.
getRecord :: RecordInfo -> Get Record
getRecord recordInfo@(RecordInfo fields) = do
  record <- Record <$> mapM getValue fields
  when (hasVariableData recordInfo) $ do
    _ <- getAllVariableData
    return ()
  return record

instance Binary BlockIndex where
    get = do
      arraySize <- label "Index Array Size" $ fromIntegral <$> getWord32le
      let numBlockIndexBytes = arraySize * 8
      blocks <- label ("Reading block of size " ++ show arraySize) $
                isolate numBlockIndexBytes $
                replicateM arraySize (fromIntegral <$> getWord64le)
      return $ BlockIndex $ listArray (0, arraySize-1) blocks

    put (BlockIndex blockIndex) = do
      let (_, iMax) = bounds blockIndex
      putWord32le $ fromIntegral $ iMax + 1
      mapM_ (putWord64le . fromIntegral) $ elems blockIndex

instance Binary Block where
  get =
    let tryGetOne = do
          done <- isEmpty
          if done
             then return Nothing
             else Just <$> get :: Get (Maybe Miniblock)
    in NT.pack <$>
       BSL.fromChunks <$>
       Prelude.map NT.unpack <$>
       unfoldM tryGetOne
  put (Block bs) =
    case BSL.toChunks bs of
      [] -> put $ Miniblock $ BS.empty
      xs -> mapM_ (put . Miniblock) xs

instance Binary Miniblock where
  get = do
    writtenSize <- label "Block size" getWord32le
    let compressionBitIndex = 31
    let isCompressed = not $ testBit writtenSize compressionBitIndex
    let size = fromIntegral $ clearBit writtenSize compressionBitIndex

    bs <- label ("Block of size " ++ show size) $ isolate size $ getByteString $ size
    let chunk = if isCompressed
                then case decompressByteStringFixed bufferSize bs of
                  Nothing -> fail "Unable to decompress. Increase buffer size?"
                  Just x -> return $ x
                else return bs
    Miniblock <$> chunk
  put (Miniblock bs) = do
    let compressionBitIndex = 31
    let compressedBlock = compressByteStringFixed ((BS.length bs)-1) bs
    let blockToWrite = case compressedBlock of
          Nothing -> bs
          Just x  -> x
    let size = BS.length blockToWrite
    let writtenSize = if isJust compressedBlock
                      then size
                      else setBit size compressionBitIndex
    putWord32le $ fromIntegral writtenSize
    putByteString blockToWrite

instance Binary Header where
    put header = do
      let actualDescriptionBS  = BS.take 64 $ encodeUtf8 $ header ^. description
      let numPaddingBytes      = fromIntegral $ 64 - BS.length actualDescriptionBS
      let paddingDescriptionBS = BSL.toStrict $ BSL.take numPaddingBytes $ BSL.repeat 0

      putByteString actualDescriptionBS
      putByteString paddingDescriptionBS
      putWord32le   $ header ^. fileId
      putWord32le   $ truncate $ utcTimeToPOSIXSeconds $ header ^. creationDate
      putWord32le   $ header ^. flags1
      putWord32le   $ header ^. flags2
      putWord32le   $ header ^. metaInfoLength
      putWord32le   $ header ^. mystery
      putWord64le   $ header ^. spatialIndexPos
      putWord64le   $ header ^. recordBlockIndexPos
      putWord64le   $ header ^. numRecords
      putWord32le   $ header ^. compressionVersion
      putByteString $ header ^. reservedSpace

    get = do
        fDescription         <- label "Description" $ decodeUtf8 <$> getByteString 64
        fFileId              <- label "FileId"              getWord32le
        fCreationDate        <- label "Creation Date"       getWord32le
        fFlags1              <- label "Flags 1"             getWord32le
        fFlags2              <- label "Flags 2"             getWord32le
        fMetaInfoLength      <- label "Metadata Length"     getWord32le
        fMystery             <- label "Mystery Field"       getWord32le
        fSpatialIndexPos     <- label "Spatial Index"       getWord64le
        fRecordBlockIndexPos <- label "Record Block"        getWord64le
        fNumRecords          <- label "Num Records"         getWord64le
        fCompressionVersion  <- label "Compression Version" getWord32le
        fReservedSpace       <- label "Reserved Space" $ (BS.concat . BSL.toChunks <$> getRemainingLazyByteString)

        return $ Header {
            _description         = fDescription,
            _fileId              = fFileId,
            _creationDate        = posixSecondsToUTCTime $ fromIntegral fCreationDate,
            _flags1              = fFlags1,
            _flags2              = fFlags2,
            _metaInfoLength      = fMetaInfoLength,
            _mystery             = fMystery,
            _spatialIndexPos     = fSpatialIndexPos,
            _recordBlockIndexPos = fRecordBlockIndexPos,
            _numRecords          = fNumRecords,
            _compressionVersion  = fCompressionVersion,
            _reservedSpace       = fReservedSpace
        }
