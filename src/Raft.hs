{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric  #-}
{-# LANGUAGE RecordWildCards #-}
module Raft where

import           Control.Distributed.Process
import           Data.Time.Clock
import Control.Monad.Random
import Control.Monad.State
import           Data.Binary                      (Binary)
import           GHC.Generics                     (Generic)
import Data.Typeable (Typeable)
import Debug.Trace
import Control.Lens.TH
import Control.Lens
import Data.Maybe
import qualified Data.Set as Set

data ServerState
    = Leader
    | Candidate
    | Follower
    deriving (Show)

data RaftState = RaftState
    { _currentTerm :: Int
    , _votedFor :: Maybe NodeId
    , _state :: ServerState
    , _timeOut :: UTCTime
    -- Read-only
    , _nodeId :: NodeId
    , _otherNodes :: [NodeId]
    } deriving (Show)
makeLenses ''RaftState

data RMessage
    = RequestVote { term :: Int
                  , candidateId :: NodeId}
    | RequestVoteAnswer { term :: Int
                        , voterId :: NodeId
                        , voteGranted :: Bool}
    | AppendEntries { term :: Int
                    , leaderId :: NodeId}
    deriving (Show,Generic,Binary)


type RProcess = StateT RaftState Process

getTimeout :: IO UTCTime
getTimeout = do delay <- getRandomR (0.150 :: Float, 0.300)
                now <- getCurrentTime
                return $ addUTCTime (realToFrac delay) now

resetTimeout :: RProcess ()
resetTimeout = do
    newTimeOut <- liftIO getTimeout
    timeOut .= newTimeOut


computeDelay :: RProcess Int
computeDelay = do
    timeOutDiff <- diffUTCTime <$> use timeOut <*> liftIO getCurrentTime
    return (round $ 1000000 * realToFrac timeOutDiff)


initialState nodeId otherNodes = RaftState 0 Nothing Follower <$> getTimeout <*> pure nodeId <*> pure otherNodes

runNode :: NodeId -> [NodeId] -> Process ()
runNode nodeId otherNodes = evalStateT followerProcess =<< liftIO (initialState nodeId otherNodes)

followerProcess :: RProcess ()
followerProcess = do
    timeoutDelay <- computeDelay
    msg <- lift $ expectTimeout timeoutDelay
    case msg of
        Just r@RequestVote {..} -> handleVoteRequest r
        Just r@AppendEntries{..} -> handleAppendEntries r
        Just r -> traceM ("Unhandled message " ++ show r) >> followerProcess
        Nothing -> do
            traceM "Follower timeout, turning into candidate"
            runForCandidate

handleAppendEntries :: RMessage -> RProcess ()
handleAppendEntries r@AppendEntries {..} = do
    traceShowM r
    myTerm <- use currentTerm
    when (term > myTerm) $
        do traceM $ "Bowing to " ++ show leaderId ++ " for term " ++ show term
           currentTerm .= term
           votedFor .= Nothing
    followerProcess

handleVoteRequest :: RMessage -> RProcess ()
handleVoteRequest r@RequestVote {..} = do
    traceM $ "received request " ++ show r
    myTerm <- use currentTerm
    currentVotedFor <- use votedFor
    myId <- use nodeId
    let agree = myTerm < term && (isNothing currentVotedFor || currentVotedFor == Just candidateId)
    when agree $
        do votedFor ?= candidateId
           resetTimeout
           traceM $ "voting for " ++ show candidateId
    sendTo candidateId (RequestVoteAnswer term myId agree)
    followerProcess

runForCandidate :: RProcess ()
runForCandidate = do
    myTerm <- currentTerm <+= 1
    traceM $ "Candidate for term " ++ show myTerm
    sendToAll =<< RequestVote myTerm <$> use nodeId
    resetTimeout
    myId <- use nodeId
    candidateProcess (Set.singleton myId)


candidateProcess :: Set.Set NodeId -> RProcess ()
candidateProcess voters = do
    timeoutDelay <- computeDelay
    msg <- lift $ expectTimeout timeoutDelay
    case msg of
        Just r@RequestVote {..} ->
            ensuringCurrentTerm term $ candidateProcess voters
        Just r@RequestVoteAnswer {..} ->
            ensuringCurrentTerm term $
            if voteGranted
                then do
                    let newVoters = Set.insert voterId voters
                    traceM $ "Voters : " ++ show newVoters
                    nodes <- use otherNodes
                    myTerm <- use currentTerm
                    if Set.size newVoters * 2 > length nodes + 1
                        then traceM
                                 ("Yay, I'm the leader! Term " ++ show myTerm) >>
                             leaderProcess
                        else candidateProcess newVoters
                else candidateProcess voters
        Just r@AppendEntries {..} -> do
            myTerm <- use currentTerm
            if myTerm <= term
                then handleAppendEntries r
                else candidateProcess voters
        Just _ -> candidateProcess voters
        Nothing ->
            traceM "Election stalemate, running again" >> runForCandidate

leaderProcess :: RProcess ()
leaderProcess = do
    myTerm <- use currentTerm
    myId <- use nodeId
    sendToAll (AppendEntries myTerm myId)
    msg <- lift $ expectTimeout 10000
    case msg of
        Just r -> ensuringCurrentTerm (term r) leaderProcess
        _ -> leaderProcess

ensuringCurrentTerm :: Int -> RProcess () -> RProcess ()
ensuringCurrentTerm term action = do
    myTerm <- use currentTerm
    if myTerm < term
        then do
            traceM "Encountered a newer term, resetting"
            currentTerm .= term
            votedFor .= Nothing
            followerProcess
        else action

sendTo :: (Typeable a, Binary a) => NodeId -> a -> RProcess ()
sendTo node msg = lift $ nsendRemote node "receiver" msg

sendToAll :: (Typeable a, Binary a) => a -> RProcess ()
sendToAll msg = do
    nodes <- use otherNodes
    mapM_ (`sendTo` msg) nodes
