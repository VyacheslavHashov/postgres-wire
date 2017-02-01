module Protocol where

import Data.Monoid ((<>))
import Data.Foldable
import Control.Monad

import Test.Tasty
import Test.Tasty.HUnit

import Database.PostgreSQL.Driver.Connection
import Database.PostgreSQL.Protocol.Types

import Connection

testProtocolMessages :: TestTree
testProtocolMessages = testGroup "Protocol messages"
    [ testCase "Simple query " testSimpleQuery
    , testCase "Extended query" testExtendedQuery
    , testCase "Extended query empty query" testExtendedEmptyQuery
    , testCase "Extended query no data" testExtendedQueryNoData
    ]

-- | Tests multi-command simple query.
testSimpleQuery :: IO ()
testSimpleQuery = withConnectionAll $ \c -> do
    let rawConn = connRawConnection c
        statement = StatementSQL $
               "DROP TABLE IF EXISTS a;"
            <> "CREATE TABLE a(v int);"
            <> "INSERT INTO a VALUES (1), (2), (3);"
            <> "SELECT * FROM a;"
            <> "DROP TABLE a;"
    sendMessage rawConn $ SimpleQuery statement
    msgs <- collectBeforeReadyForQuery c
    assertNoErrorResponse msgs
    assertContains msgs isCommandComplete "Command complete"
  where
    isCommandComplete (CommandComplete _) = True
    isCommandComplete _                   = False

-- Tests all messages that are permitted in extended query protocol.
testExtendedQuery :: IO ()
testExtendedQuery = withConnectionAll $ \c -> do
    let rawConn = connRawConnection c
        sname = StatementName "statement"
        pname = PortalName "portal"
        statement = StatementSQL "SELECT $1 + $2"
    sendMessage rawConn $ Parse sname statement [Oid 23, Oid 23]
    sendMessage rawConn $
        Bind pname sname Text ["1", "2"] Text
    sendMessage rawConn $ Execute pname noLimitToReceive
    sendMessage rawConn $ DescribeStatement sname
    sendMessage rawConn $ DescribePortal pname
    sendMessage rawConn $ CloseStatement sname
    sendMessage rawConn $ ClosePortal pname
    sendMessage rawConn Flush
    sendMessage rawConn Sync

    msgs <- collectBeforeReadyForQuery c
    assertNoErrorResponse msgs
    assertContains msgs isBindComplete "BindComplete"
    assertContains msgs isCloseComplete "CloseComplete"
    assertContains msgs isParseComplete "ParseComplete"
    assertContains msgs isDataRow "DataRow"
    assertContains msgs isCommandComplete "CommandComplete"
    assertContains msgs isParameterDecription "ParameterDescription"
    assertContains msgs isRowDescription "RowDescription"
  where
    isBindComplete          BindComplete             = True
    isBindComplete          _                        = False
    isCloseComplete         CloseComplete            = True
    isCloseComplete         _                        = False
    isParseComplete         ParseComplete            = True
    isParseComplete         _                        = False
    isDataRow               (DataRow _)              = True
    isDataRow               _                        = False
    isCommandComplete       (CommandComplete _)      = True
    isCommandComplete       _                        = False
    isParameterDecription   (ParameterDescription _) = True
    isParameterDecription   _                        = False
    isRowDescription        (RowDescription _)       = True
    isRowDescription        _                        = False

-- | Tests that PostgreSQL returns `EmptyQueryResponse` when a query
-- string is empty.
testExtendedEmptyQuery :: IO ()
testExtendedEmptyQuery = withConnectionAll $ \c -> do
    let query = Query "" [] [] Text Text
    sendBatchAndSync c [query]
    msgs <- collectBeforeReadyForQuery c
    assertNoErrorResponse msgs
    assertContains msgs isEmptyQueryResponse "EmptyQueryResponse"
  where
    isEmptyQueryResponse EmptyQueryResponse = True
    isEmptyQueryResponse _ = False

-- | Tests that `desribe statement` receives NoData when a statement
-- has no data in the result.
testExtendedQueryNoData :: IO ()
testExtendedQueryNoData = withConnectionAll $ \c -> do
    let rawConn   = connRawConnection c
        sname     = StatementName "statement"
        statement = StatementSQL "SET client_encoding to UTF8"
    sendMessage rawConn $ Parse sname statement []
    sendMessage rawConn $ DescribeStatement sname
    sendMessage rawConn Sync

    msgs <- collectBeforeReadyForQuery c
    assertContains msgs isNoData "NoData"
  where
    isNoData NoData = True
    isNoData _      = False

-- | Assert that list contains element satisfies predicat.
assertContains
    :: [ServerMessage] -> (ServerMessage -> Bool) -> String -> Assertion
assertContains msgs f name
    = assertBool ("Does not contain" ++ name) $ any f msgs

-- | Assert there are on `ErrorResponse` in the list.
assertNoErrorResponse :: [ServerMessage] -> Assertion
assertNoErrorResponse
    = assertBool "Occured ErrorResponse" . all (not . isError)
  where
    isError (ErrorResponse _) = True
    isError _ = False
