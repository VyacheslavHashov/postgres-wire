{-# language RecordWildCards #-}

module Database.PostgreSQL.Protocol.Decoders
    ( decodeAuthResponse
    , decodeServerMessage
    -- * Helpers
    , parseServerVersion
    , parseIntegerDatetimes
    ) where

import           Control.Applicative
import           Control.Monad
import           Data.Monoid ((<>))
import           Data.Maybe (fromMaybe)
import           Data.Char (chr)
import           Text.Read (readMaybe)
import qualified Data.Vector as V
import qualified Data.ByteString as B
import           Data.ByteString.Char8 as BS(readInteger, readInt, unpack, pack)
import qualified Data.HashMap.Strict as HM

import Database.PostgreSQL.Protocol.Types
import Database.PostgreSQL.Protocol.Store.Decode

decodeAuthResponse :: Decode AuthResponse
decodeAuthResponse = do
    c <- getWord8
    len <- getInt32BE
    case chr $ fromIntegral c of
        'E' -> AuthErrorResponse <$>
            (getByteString (fromIntegral $ len - 4) >>=
                eitherToDecode .parseErrorDesc)
        'R' -> do
            rType <- getInt32BE
            case rType of
                0 -> pure AuthenticationOk
                3 -> pure AuthenticationCleartextPassword
                5 -> AuthenticationMD5Password . MD5Salt <$> getByteString 4
                7 -> pure AuthenticationGSS
                9 -> pure AuthenticationSSPI
                8 -> AuthenticationGSSContinue <$>
                        getByteString (fromIntegral $ len -8)
                _ -> fail "Unknown authentication response"
        _ -> fail "Invalid auth response"

decodeServerMessage :: Decode ServerMessage
decodeServerMessage = do
    c <- getWord8
    len <- getInt32BE
    case chr $ fromIntegral c of
        'K' -> BackendKeyData <$> (ServerProcessId <$> getInt32BE)
                              <*> (ServerSecretKey <$> getInt32BE)
        '2' -> pure BindComplete
        '3' -> pure CloseComplete
        'C' -> CommandComplete <$> (getByteString (fromIntegral $ len - 4)
                                    >>= eitherToDecode . parseCommandResult)
        'D' -> do
            columnCount <- fromIntegral <$> getInt16BE
            DataRow <$> V.replicateM columnCount decodeValue
        'I' -> pure EmptyQueryResponse
        'E' -> ErrorResponse <$>
            (getByteString (fromIntegral $ len - 4) >>=
                eitherToDecode . parseErrorDesc)
        'n' -> pure NoData
        'N' -> NoticeResponse <$>
            (getByteString (fromIntegral $ len - 4) >>=
                eitherToDecode . parseNoticeDesc)
        'A' -> NotificationResponse <$> decodeNotification
        't' -> do
            paramCount <- fromIntegral <$> getInt16BE
            ParameterDescription <$> V.replicateM paramCount
                                     (Oid <$> getInt32BE)
        'S' -> ParameterStatus <$> getByteStringNull <*> getByteStringNull
        '1' -> pure ParseComplete
        's' -> pure PortalSuspended
        'Z' -> ReadForQuery <$> decodeTransactionStatus
        'T' -> do
            rowsCount <- fromIntegral <$> getInt16BE
            RowDescription <$> V.replicateM rowsCount decodeFieldDescription

-- | Decodes a single data value. Length `-1` indicates a NULL column value.
-- No value bytes follow in the NULL case.
decodeValue :: Decode (Maybe B.ByteString)
decodeValue = getInt32BE >>= \n ->
    if n == -1
    then pure Nothing
    else Just <$> getByteString (fromIntegral n)

decodeTransactionStatus :: Decode TransactionStatus
decodeTransactionStatus =  getWord8 >>= \t ->
    case chr $ fromIntegral t of
        'I' -> pure TransactionIdle
        'T' -> pure TransactionInBlock
        'E' -> pure TransactionFailed
        _   -> fail "unknown transaction status"

decodeFieldDescription :: Decode FieldDescription
decodeFieldDescription = FieldDescription
    <$> getByteStringNull
    <*> (Oid <$> getInt32BE)
    <*> getInt16BE
    <*> (Oid <$> getInt32BE)
    <*> getInt16BE
    <*> getInt32BE
    <*> decodeFormat

decodeNotification :: Decode Notification
decodeNotification = Notification
    <$> (ServerProcessId <$> getInt32BE)
    <*> (ChannelName <$> getByteStringNull)
    <*> getByteStringNull

decodeFormat :: Decode Format
decodeFormat = getInt16BE >>= \f ->
    case f of
        0 -> pure Text
        1 -> pure Binary
        _ -> fail "Unknown field format"

-- Parser that just work with B.ByteString, not Decode type

-- Helper to parse, not used by decoder itself
parseServerVersion :: B.ByteString -> Maybe ServerVersion
parseServerVersion bs =
    let (numbersStr, desc) = B.span isDigitDot bs
        numbers = readMaybe . BS.unpack <$> B.split 46 numbersStr
    in case numbers ++ repeat (Just 0) of
        (Just major : Just minor : Just rev : _) ->
            Just $ ServerVersion major minor rev desc
        _ -> Nothing
  where
    isDigitDot c | c == 46           = True -- dot
                 | c >= 48 && c < 58 = True -- digits
                 | otherwise         = False

-- Helper to parse, not used by decoder itself
parseIntegerDatetimes :: B.ByteString -> Bool
parseIntegerDatetimes  bs | bs == "on" || bs == "yes" || bs == "1" = True
                          | otherwise                              = False

parseCommandResult :: B.ByteString -> Either B.ByteString CommandResult
parseCommandResult s =
    let (command, rest) = B.break (== space) s
    in case command of
        -- format: `INSERT oid rows`
        "INSERT" ->
            maybe (Left "Invalid format in INSERT command result") Right $ do
                (oid, r) <- readInteger $ B.dropWhile (== space) rest
                (rows, _) <- readInteger $ B.dropWhile (== space) r
                Just $ InsertCompleted (Oid $ fromInteger oid)
                                       (RowsCount $ fromInteger rows)
        "DELETE" -> DeleteCompleted <$> readRows rest
        "UPDATE" -> UpdateCompleted <$> readRows rest
        "SELECT" -> SelectCompleted <$> readRows rest
        "MOVE"   -> MoveCompleted   <$> readRows rest
        "FETCH"  -> FetchCompleted  <$> readRows rest
        "COPY"   -> CopyCompleted   <$> readRows rest
        _        -> Right CommandOk
  where
    space = 32
    readRows = maybe (Left "Invalid rows format in command result")
                       (pure . RowsCount . fromInteger . fst)
                       . readInteger . B.dropWhile (== space)

parseErrorNoticeFields :: B.ByteString -> HM.HashMap Char B.ByteString
parseErrorNoticeFields = HM.fromList
    . fmap (\s -> (chr . fromIntegral $ B.head s, B.tail s))
    . filter (not . B.null) . B.split 0

parseErrorSeverity :: B.ByteString -> ErrorSeverity
parseErrorSeverity bs = case bs of
    "ERROR" -> SeverityError
    "FATAL" -> SeverityFatal
    "PANIC" -> SeverityPanic
    _       -> UnknownErrorSeverity

parseNoticeSeverity :: B.ByteString -> NoticeSeverity
parseNoticeSeverity bs = case bs of
    "WARNING" -> SeverityWarning
    "NOTICE"  -> SeverityNotice
    "DEBUG"   -> SeverityDebug
    "INFO"    -> SeverityInfo
    "LOG"     -> SeverityLog
    _         -> UnknownNoticeSeverity

parseErrorDesc :: B.ByteString -> Either B.ByteString ErrorDesc
parseErrorDesc s = do
    let hm = parseErrorNoticeFields s
    errorSeverityOld <- lookupKey 'S' hm
    errorCode        <- lookupKey 'C' hm
    errorMessage     <- lookupKey 'M' hm
    let
        -- This is identical to the S field except that the contents are
        -- never localized. This is present only in messages generated by
        -- PostgreSQL versions 9.6 and later.
        errorSeverityNew      = HM.lookup 'V' hm
        errorSeverity         = parseErrorSeverity $
                                fromMaybe errorSeverityOld errorSeverityNew
        errorDetail           = HM.lookup 'D' hm
        errorHint             = HM.lookup 'H' hm
        errorPosition         = HM.lookup 'P' hm >>= fmap fst . readInt
        errorInternalPosition = HM.lookup 'p' hm >>= fmap fst . readInt
        errorInternalQuery    = HM.lookup 'q' hm
        errorContext          = HM.lookup 'W' hm
        errorSchema           = HM.lookup 's' hm
        errorTable            = HM.lookup 't' hm
        errorColumn           = HM.lookup 'c' hm
        errorDataType         = HM.lookup 'd' hm
        errorConstraint       = HM.lookup 'n' hm
        errorSourceFilename   = HM.lookup 'F' hm
        errorSourceLine       = HM.lookup 'L' hm >>= fmap fst . readInt
        errorSourceRoutine    = HM.lookup 'R' hm
    Right ErrorDesc{..}
  where
    lookupKey c = maybe (Left $ "Neccessary key " <> BS.pack (show c) <>
                         "is not presented in ErrorResponse message")
                         Right . HM.lookup c

parseNoticeDesc :: B.ByteString -> Either B.ByteString NoticeDesc
parseNoticeDesc s = do
    let hm = parseErrorNoticeFields s
    noticeSeverityOld <- lookupKey 'S' hm
    noticeCode        <- lookupKey 'C' hm
    noticeMessage     <- lookupKey 'M' hm
    let
        -- This is identical to the S field except that the contents are
        -- never localized. This is present only in messages generated by
        -- PostgreSQL versions 9.6 and later.
        noticeSeverityNew      = HM.lookup 'V' hm
        noticeSeverity         = parseNoticeSeverity $
                                fromMaybe noticeSeverityOld noticeSeverityNew
        noticeDetail           = HM.lookup 'D' hm
        noticeHint             = HM.lookup 'H' hm
        noticePosition         = HM.lookup 'P' hm >>= fmap fst . readInt
        noticeInternalPosition = HM.lookup 'p' hm >>= fmap fst . readInt
        noticeInternalQuery    = HM.lookup 'q' hm
        noticeContext          = HM.lookup 'W' hm
        noticeSchema           = HM.lookup 's' hm
        noticeTable            = HM.lookup 't' hm
        noticeColumn           = HM.lookup 'c' hm
        noticeDataType         = HM.lookup 'd' hm
        noticeConstraint       = HM.lookup 'n' hm
        noticeSourceFilename   = HM.lookup 'F' hm
        noticeSourceLine       = HM.lookup 'L' hm >>= fmap fst . readInt
        noticeSourceRoutine    = HM.lookup 'R' hm
    Right NoticeDesc{..}
  where
    lookupKey c = maybe (Left $ "Neccessary key " <> BS.pack (show c) <>
                         "is not presented in NoticeResponse message")
                         Right . HM.lookup c

eitherToDecode :: Either B.ByteString a -> Decode a
eitherToDecode = either (fail . BS.unpack) pure

