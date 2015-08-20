{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE RankNTypes #-}

module Wheb.Plugins.Session 
  ( SessionContainer (..)
  , SessionApp (..)
  , SessionBackend (..)
  
  , setSessionValue
  , getSessionValue
  , getSessionValue'
  , deleteSessionValue
  , generateSessionKey
  , getCurrentSessionKey
  , clearSessionKey
  ) where
    
import Control.Monad (liftM)
import Control.Monad.IO.Class (MonadIO(..))
import Data.Maybe (fromMaybe)
import Data.Text (pack, Text)
import Wheb (getWithApp, WhebT)
import Wheb.Cookie (getCookie, setCookie)
import Wheb.Utils (makeUUID)

-- | Initial pass on abstract plugin for Sessions.
--   Possibly add support for Typable to ease typecasting.

session_cookie_key :: Text
session_cookie_key = pack "-session-"

data SessionContainer = forall r. SessionBackend r => SessionContainer r

class SessionApp a where
  getSessionContainer :: a -> SessionContainer

class SessionBackend c where
  backendSessionPut    :: (SessionApp a, MonadIO m) => Text -> Text -> Text -> c -> WhebT a b m ()
  backendSessionGet    :: (SessionApp a, MonadIO m) => Text -> Text -> c -> WhebT a b m (Maybe Text)
  backendSessionDelete :: (SessionApp a, MonadIO m) => Text -> Text -> c -> WhebT a b m ()
  backendSessionClear  :: (SessionApp a, MonadIO m) => Text -> c -> WhebT a b m ()

runWithContainer :: (SessionApp a, MonadIO m) => (forall r. SessionBackend r => r -> WhebT a s m b) -> WhebT a s m b
runWithContainer f = do
  SessionContainer sessStore <- getWithApp getSessionContainer
  f sessStore

deleteSessionValue :: (SessionApp a, MonadIO m) => Text -> WhebT a b m ()
deleteSessionValue key= do
      sessId <- getCurrentSessionKey 
      runWithContainer $ backendSessionDelete sessId key

setSessionValue :: (SessionApp a, MonadIO m) => Text -> Text -> WhebT a b m ()
setSessionValue key content = do
      sessId <- getCurrentSessionKey 
      runWithContainer $ backendSessionPut sessId key content

getSessionValue :: (SessionApp a, MonadIO m) => Text -> WhebT a b m (Maybe Text)
getSessionValue key = do
      sessId <- getCurrentSessionKey
      runWithContainer $ backendSessionGet sessId key

getSessionValue' :: (SessionApp a, MonadIO m) => Text -> Text -> WhebT a b m Text
getSessionValue' def key = liftM (fromMaybe def) (getSessionValue key)
      
getSessionCookie :: (SessionApp a, MonadIO m) => WhebT a b m (Maybe Text)
getSessionCookie = getCookie session_cookie_key
    
generateSessionKey :: (SessionApp a, MonadIO m) => WhebT a b m Text
generateSessionKey = do
  newKey <- makeUUID
  setCookie session_cookie_key newKey
  return newKey

getCurrentSessionKey :: (SessionApp a, MonadIO m) => WhebT a b m Text
getCurrentSessionKey = do
    curKey <- getSessionCookie
    case curKey of
      Just key -> return key
      Nothing -> generateSessionKey

clearSessionKey :: (SessionApp a, MonadIO m) => WhebT a b m Text
clearSessionKey = do
    curKey <- getSessionCookie
    newKey <- generateSessionKey
    case curKey of
      Nothing -> return newKey
      Just oldKey -> do
          runWithContainer $ backendSessionClear oldKey
          return newKey