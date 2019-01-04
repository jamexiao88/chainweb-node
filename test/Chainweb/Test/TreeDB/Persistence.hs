{-# LANGUAGE TypeApplications #-}

-- |
-- Module: Chainweb.Test.TreeDB.Persistence
-- Copyright: Copyright © 2018 Kadena LLC.
-- License: MIT
-- Maintainer: Lars Kuhtz <lars@kadena.io>
-- Stability: experimental
--
-- TODO
--
module Chainweb.Test.TreeDB.Persistence
( tests
) where

import Control.Monad (void)
import Control.Monad.Trans.Resource (ResourceT, runResourceT)

import Data.Align (padZipWith)

import qualified Streaming.Prelude as S

import System.Path (fromAbsoluteFilePath)

import Test.Tasty
import Test.Tasty.HUnit

-- internal modules

import Chainweb.ChainId (ChainId, testChainId)
import Chainweb.Test.Utils (insertN, withDB)
import Chainweb.TreeDB
import Chainweb.TreeDB.Persist (fileEntries, persist)

---

chainId0 :: ChainId
chainId0 = testChainId 0

tests :: TestTree
tests = testGroup "Persistence"
    [ testGroup "Encoding round-trips"
        [ testCase "Fresh TreeDb (only genesis)" onlyGenesis
        , testCase "Multiple Entries" manyBlocksWritten
        ]
    ]

-- | Persisting a freshly initialized `TreeDb` will successfully read and
-- write its only block, the genesis block.
--
onlyGenesis :: Assertion
onlyGenesis = withDB chainId0 $ \g db -> do
    persist fp db
    g' <- runResourceT . S.head_ $ fileEntries @(ResourceT IO) fp
    g' @?= Just g
  where
    fp = fromAbsoluteFilePath "/tmp/only-genesis"

-- | Write a number of block headers to a database, persist that database,
-- reread it, and compare. Guarantees:
--
--  * The DB and its persistence will have the same contents in the same order.
--  * The first block streamed from both the DB and the file will be the genesis.
--
manyBlocksWritten :: Assertion
manyBlocksWritten = withDB chainId0 $ \g db -> do
    void $ insertN len g db
    persist fp db
    fromDB <- S.toList_ $ entries db Nothing Nothing Nothing Nothing
    fromFi <- runResourceT . S.toList_ $ fileEntries fp
    length fromDB @?= len + 1
    length fromFi @?= len + 1
    head fromDB @?= g
    head fromFi @?= g
    let b = and $ padZipWith (==) fromDB fromFi
    assertBool "Couldn't write many blocks" b
  where
    fp  = fromAbsoluteFilePath "/tmp/many-blocks-written"
    len = 10