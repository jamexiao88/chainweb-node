{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}

-- | Module: Main
-- Copyright: Copyright © 2019 Kadena LLC.
-- License: MIT
-- Maintainer: Emmanuel Denloye-Ito <emamnuel@kadena.io>
-- Stability: experimental
--
-- TODO
--

module Main where

import Configuration.Utils hiding (Error, Lens', (<.>))
import Control.Concurrent (threadDelay)
import Control.Lens hiding ((.=))
import Control.Monad.Primitive
import Control.Monad.Reader
import Control.Monad.State
import Control.Monad.Except

import Data.Default (def, Default (..))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Text (Text)
import Data.Word (Word16)

import Fake (generate, fake)

import Network.HTTP.Client

import GHC.Generics

import Servant.Client

import System.Random
import System.Random.MWC (Gen, asGenIO, uniformR, withSystemRandom)
import System.Random.MWC.Distributions (normal)

-- -- PACT
import Pact.Server.Client
import Pact.Types.API
import Pact.Types.Command (Command (..))
import Pact.Types.Crypto (SomeKeyPair)

-- CHAINWEB
import Chainweb.ChainId
-- THIS MODULE MAY BE USED LATER
-- import Chainweb.Simulate.Contracts.CommercialPaper
import Chainweb.Simulate.Contracts.CryptoCritters
import Chainweb.Simulate.Contracts.HelloWorld
import Chainweb.Simulate.Contracts.SimplePayments
import Chainweb.Simulate.Utils


data TransactionCommand = NoOp | Init | Run
  deriving (Show, Eq, Read, Generic)

instance FromJSON TransactionCommand

instance ToJSON TransactionCommand

data TransactionConfig = TransactionConfig
  { _scriptCommand :: TransactionCommand
  , _nodeChainId :: !ChainId
  , _nodePort :: !Word16
  , _serverRootPath :: String
  } deriving (Generic)

makeLenses ''TransactionConfig

instance ToJSON TransactionConfig where
  toJSON o =
    object
      [ "scriptCommand" .= _scriptCommand o
      , "nodeChainId" .= _nodeChainId o
      , "nodePort" .= _nodePort o
      ]

instance FromJSON (TransactionConfig -> TransactionConfig) where
  parseJSON = withObject "TransactionConfig" $ \o -> id
    <$< scriptCommand ..: "scriptCommand" % o
    <*< nodeChainId ..: "nodeChainId" % o
    <*< nodePort ..: "nodePort" % o

defaultTransactionConfig :: TransactionConfig
defaultTransactionConfig =
  TransactionConfig
    { _scriptCommand = Init
    , _nodeChainId = testChainId 1
    , _nodePort = tmpNodePort
    , _serverRootPath = "http://localhost:" ++ show tmpNodePort
    }
  where
    tmpNodePort = 8080          -- this is default port according to the "pact -s" docs

transactionConfigParser :: MParser TransactionConfig
transactionConfigParser = id
  <$< scriptCommand .:: option auto
      % long "script-command" <> short 'c'
      <> help "The specific command to run (Init|Run)."
  <*< nodeChainId .::option auto
      % long "node-chain-id"
      <> short 'i'
      <> help "The specific chain that will receive generated \"fake\" transactions."
  <*< nodePort .:: option auto
      % long "port"
      <> short 'p'
      <> help "The TCP port this transaction generator node uses."

data TimingDistribution
  = Gaussian { mean :: Int
             , var :: Int }
  | Uniform { low :: Int
            , high :: Int }
  deriving (Eq, Show)

instance Default TimingDistribution where
  def = Gaussian 1000000 (div 1000000 16)

data GeneratorConfig = GeneratorConfig
  { _timingdist :: TimingDistribution
  , _transactionCount :: IORef Integer
  , _genAccountsKeysets :: [(Account, [SomeKeyPair])]
  , _genClientEnv :: ClientEnv
  }

makeLenses ''GeneratorConfig

generateTransaction :: TransactionGenerator (PrimState IO) (Command Text)
generateTransaction = do
  contractIndex <- liftIO $ randomRIO (1, numContracts)
  sample <-
    case contractIndex of
      1 -> do
        liftIO $ do
            name <- generate fake
            helloRequest name
      2 -> do
        kacts <- view genAccountsKeysets
        liftIO $ do
            paymentsRequest <- mkRandomSimplePaymentRequest kacts >>= generate
            print paymentsRequest -- This is for debugging purposes
            case paymentsRequest of
                RequestPay fromAccount _ _ ->
                        let errmsg = "This account does not have an associated keyset!"
                            mkeyset = maybe (fail errmsg) Just (lookup fromAccount kacts)
                        in createSimplePaymentRequest paymentsRequest mkeyset
                _ -> createSimplePaymentRequest paymentsRequest Nothing
      3 -> liftIO $ undefined
      _ -> fail "No contract here"
  distribution <- view timingdist
  gen <- get
  delay <-
    case distribution of
      Gaussian gmean gvar ->
        truncate <$>
        liftIO (normal (fromIntegral gmean) (fromIntegral gvar) gen)
      Uniform ulow uhigh -> liftIO (uniformR (ulow, uhigh) gen)
  liftIO $ threadDelay delay
  liftIO $ putStrLn ("The delay is " ++ (show delay) ++ " seconds.")
  return sample

newtype TransactionGenerator s a = TransactionGenerator
  { runTransactionGenerator :: ReaderT GeneratorConfig (StateT (Gen s) IO) a
  } deriving ( Functor , Applicative , Monad , MonadIO , MonadState (Gen s) , MonadReader GeneratorConfig)


sendTransaction :: Command Text -> TransactionGenerator (PrimState IO) (Either ServantError PollResponses)
sendTransaction cmd = do
  cenv <- view genClientEnv
  liftIO $ runExceptT $ do
    rkeys <-
      ExceptT $
      runClientM (send pactServerApiClient (SubmitBatch [cmd])) cenv
    ExceptT $
      runClientM
        (poll pactServerApiClient (Poll (_rkRequestKeys rkeys)))
        cenv

loop :: TransactionGenerator (PrimState IO) ()
loop = do
  transaction <- generateTransaction
  pollResponse <- sendTransaction transaction
  liftIO $ print pollResponse
  counter <- view transactionCount
  liftIO $ readIORef counter >>= (\count -> putStrLn $ "Transaction count: " ++ show count)
  liftIO $ modifyIORef' counter (+ 1)
  loop

mkGeneratorConfig :: Maybe Int -> IO GeneratorConfig
mkGeneratorConfig mport = GeneratorConfig <$> pure def <*> newIORef 0 <*> pure mempty <*> go
  where
    go = do mgr <- newManager defaultManagerSettings
            url <- parseBaseUrl ("http://localhost:" ++ maybe _testPort show mport)
            return $ mkClientEnv  mgr url

mainInfo :: ProgramInfo TransactionConfig
mainInfo =
  programInfo
    "Chainweb-TransactionGenerator"
    transactionConfigParser
    defaultTransactionConfig

_testPort :: String
_testPort = "8080"

_serverPath :: String
_serverPath = "http://localhost:" ++ _testPort

loadContracts :: IO ()
loadContracts = do
  mgr <- newManager defaultManagerSettings
  url <- parseBaseUrl _serverPath
  let clientEnv = mkClientEnv mgr url
  ts <- testSomeKeyPairs
  contracts <- traverse ($ ts) contractLoaders
  pollresponse <- runExceptT $ do
     rkeys <- ExceptT $ runClientM (send pactServerApiClient (SubmitBatch contracts)) clientEnv
     ExceptT $ runClientM (poll pactServerApiClient (Poll (_rkRequestKeys rkeys))) clientEnv
  print pollresponse

main :: IO ()
main =
  runWithConfiguration mainInfo $ \config -> do
    case _scriptCommand config of
      NoOp -> putStrLn "NoOp: You probably don't want to be here."
      Init -> loadContracts
      Run -> do
        putStrLn "Transactions are being generated"
        gencfg <- mkGeneratorConfig Nothing
        (keysets, accounts) <- unzip <$> createAccounts
        _pollresponse <-
            runExceptT $ do
                rkeys <- ExceptT $ runClientM (send pactServerApiClient (SubmitBatch accounts)) (_genClientEnv gencfg)
                ExceptT $ runClientM (poll pactServerApiClient (Poll (_rkRequestKeys rkeys))) (_genClientEnv gencfg)
        print _pollresponse
        withSystemRandom . asGenIO $ \gen ->
          evalStateT
            (runReaderT (runTransactionGenerator loop) (set genAccountsKeysets (zip accountNames keysets) gencfg))
            gen

contractLoaders :: [[SomeKeyPair] -> IO (Command Text)]
contractLoaders = initAdminKeysetContract : take numContracts [helloWorldContractLoader, simplePaymentsContractLoader, cryptoCritterContractLoader]

numContracts :: Int
numContracts = 2

-- add this back in later
-- , commercialPaperContractLoader
