{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}
module Main where
import           Control.Concurrent
import           Control.Distributed.Process
import           Control.Distributed.Process.Node
import           Control.Monad
import           Control.Monad.State
import           Data.Binary                      (Binary)
import qualified Data.ByteString.Char8            as B
import           Data.List
import           Data.Monoid
import           Data.Ord
import           Data.Time.Clock
import           Debug.Trace
import           GHC.Generics                     (Generic)
import           Network.Transport                (EndPointAddress (..))
import           Network.Transport.TCP            (createTransport,
                                                   defaultTCPParameters)
import           Options.Applicative
import           System.Random

nodes = [ ("127.0.0.1", "10501")
        , ("127.0.0.1", "10502")
        , ("127.0.0.1", "10503")
        , ("127.0.0.1", "10504")
        ]

data Config = Config { sendFor :: Integer
                     , waitFor :: Integer
                     , seed    :: Int
                     , port    :: String
                     } deriving Show

configParser :: Parser Config
configParser = Config
  <$> option auto (long "send-for" <> metavar "DURATION" <> help "How many seconds the system sends messages")
  <*> option auto (long "wait-for" <> metavar "DURATION" <> help "Length of the grace period in second")
  <*> option auto (long "with-seed" <> value 0 <> showDefault <> metavar "SEED" <> help "Random seed to use")
  <*> strOption   (long "port" <> value "10501" <> showDefault <> metavar "PORT" <> help "Port to bind to")

main :: IO ()
main = do
  config <- execParser $ info (helper <*> configParser) idm

  -- Infinite sequence of floats
  let gen = mkStdGen (seed config)
      numbers = map (1 -)  -- randoms gives us [0,1), we want (0,1]
                    (randoms gen)

  Right t <- createTransport "127.0.0.1" (port config) defaultTCPParameters
  node <- newLocalNode t initRemoteTable

  let allNodes = [ NodeId . EndPointAddress . B.pack
                   $ h <> ":" <> p <> ":0"
                 | (h, p) <- nodes]
                 :: [NodeId]
      Just myId = elemIndex (localNodeId node) allNodes
      otherNodes = delete (localNodeId node) allNodes

  _ <- runProcess node $ do
    self <- getSelfPid
    register "receiver" self

    -- TODO signalling system to start
    traceM $ "I am " <> show self <> "."
    traceM "Waiting for all nodes to come online."
    liftIO $ threadDelay $ 1000 * 1000 * 2

    traceM "Starting to send."

    now <- liftIO getCurrentTime
    let sendUntil = addUTCTime (fromInteger $ sendFor config) now
        waitUntil = addUTCTime (fromInteger $ waitFor config) sendUntil

    messages <- nodeProcess myId otherNodes sendUntil waitUntil numbers
    liftIO $ printResult messages
  return ()


data Msg = Msg { node    :: Int
               , time    :: Int
               , content :: Float
               } deriving (Show, Generic, Binary)


nodeProcess :: Int -> [NodeId] -> UTCTime -> UTCTime -> [Float] -> Process [Msg]
nodeProcess myId otherNodes sendUntil waitUntil numbers = evalStateT (exchanges numbers) 0
  where exchanges :: [Float] -> StateT Int Process [Msg]
        exchanges (content:rest) = do
          now <- liftIO getCurrentTime
          when (now < sendUntil)
            (sendToAll content)
          messages <- receiveMany
          rest <- if now < waitUntil
            then exchanges rest
            else return []
          return (messages ++ rest)

        sendToAll :: Float -> StateT Int Process ()
        sendToAll content = do modify' (+1)
                               time <- get
                               let msg = Msg myId time content
                               lift $ forM_ otherNodes (\n -> nsendRemote n "receiver" msg)

        receiveOne :: StateT Int Process (Maybe Msg)
        receiveOne = do result <- lift $ expectTimeout 100000
                        case result of
                          Just msg@Msg{ time = time} -> do modify' (\currentTime -> max currentTime time + 1)
                                                           return (Just msg)
                          Nothing -> return Nothing

        receiveMany = do r <- receiveOne
                         case r of
                           Just x -> do rest <- receiveMany
                                        return (rest ++ [x])
                           Nothing -> return []


printResult :: [Msg] -> IO ()
printResult messages = do traceShowM (drop (count - 5) sortedMessages)
                          print (count, score)
  where count = length sortedMessages
        score = sum $ zipWith (*) [1..] (map content sortedMessages)
        sortedMessages = sortBy (comparing time <> comparing node) messages
