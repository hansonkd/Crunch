module Wheb.Plugins.Debug.MemoryBackend where

import Control.Concurrent.STM (atomically, modifyTVar, newTVarIO, readTVarIO, TVar, writeTVar)
import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Data.Map as M (alter, delete, empty, insert, lookup, Map, member, update)
import Data.Maybe (fromMaybe)
import Data.Text (Text)
import Data.ByteString (ByteString)
import Wheb (InitM)
import Wheb.Plugins.Auth
import Wheb.Plugins.Cache
import Wheb.Plugins.Session

data SessionData = SessionData 
  { sessionMemory ::  TVar (M.Map Text (M.Map Text Text)) }
data UserData = UserData
  { userStorage :: TVar (M.Map UserKey PwHash) }
data CacheData = CacheData
  { cacheStorage :: TVar (M.Map Text ByteString) }


-- | In memory cache backend. Cache value
-- will not persist after server restart and will never clear old values.
instance CacheBackend CacheData where
  backendCachePut key content _ (CacheData tv) = do
    liftIO $ atomically $ modifyTVar tv (M.insert key content)
  backendCacheGet key (CacheData tv) = do
      curCache <- liftIO $ readTVarIO tv
      return $ (M.lookup key curCache)
  backendCacheDelete key (CacheData tv) =
      liftIO $ atomically $ modifyTVar tv (M.delete key)

-- | In memory session backend. Session values 
-- will not persist after server restart.
instance SessionBackend SessionData where
  backendSessionPut sessId key content (SessionData tv) =
      let insertFunc = (\sess -> 
                          Just $ M.insert key content (fromMaybe M.empty sess)
                       )
          tVarFunc = M.alter insertFunc sessId
      in liftIO $ atomically $ modifyTVar tv tVarFunc
  backendSessionGet sessId key (SessionData tv) = do
      curSessions <- liftIO $ readTVarIO tv
      return $ (M.lookup sessId curSessions) >>= (M.lookup key)
  backendSessionDelete sessId key (SessionData tv) =
      liftIO $ atomically $ modifyTVar tv (M.update (Just . (M.delete key)) sessId)
  backendSessionClear sessId (SessionData tv) =
      liftIO $ atomically $ modifyTVar tv (M.delete sessId)

-- | In memory auth backend. User values 
-- will not persist after server restart.
instance AuthBackend UserData where
  backendGetUser name (UserData tv) = do
        possUser <- liftM (M.lookup name) $ liftIO $ readTVarIO tv
        case possUser of
          Nothing -> return Nothing
          Just _ -> return $ Just (AuthUser name)
  backendLogin name pw (UserData tv) = do
        users <- liftIO $ readTVarIO $ tv
        let possUser = M.lookup name users
            passCheck = fmap (verifyPw pw) possUser
        case passCheck of
            Just True -> return (Right $ AuthUser $ name)
            Just False -> return (Left InvalidPassword)
            Nothing -> return (Left UserDoesNotExist)
  backendRegister (AuthUser name) pw (UserData tv) = do
        users <- liftIO $ readTVarIO $ tv
        if M.member name users
            then return (Left DuplicateUsername)
            else do
                pwHash <- makePwHash pw
                liftIO $ atomically $ writeTVar tv (M.insert name pwHash users)
                return (Right $ AuthUser name)
  backendLogout _ =  getUserSessionKey >>= deleteSessionValue
                
initSessionMemory :: InitM g s m SessionContainer
initSessionMemory = do
  tv <- liftIO $ newTVarIO $ M.empty
  return $! SessionContainer $ SessionData tv

initAuthMemory :: InitM g s m AuthContainer
initAuthMemory = do
  tv <- liftIO $ newTVarIO $ M.empty
  return $! AuthContainer $ UserData tv
  
initCacheMemory :: InitM g s m CacheContainer
initCacheMemory = do
  tv <- liftIO $ newTVarIO $ M.empty
  return $! CacheContainer $ CacheData tv
