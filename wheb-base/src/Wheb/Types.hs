{-# LANGUAGE ExistentialQuantification  #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor              #-}
{-# LANGUAGE Rank2Types                 #-}
{-# LANGUAGE MultiParamTypeClasses      #-}

module Wheb.Types where

import           Control.Applicative (Applicative)
import           Control.Concurrent.STM (TVar)
import           Control.Monad.Except (ExceptT(ExceptT), MonadError(..),
                                       MonadIO, MonadTrans(..))
import           Control.Monad.Reader (ReaderT(ReaderT))
import           Control.Monad.State.Strict (StateT)
import           Control.Monad.Writer ((<>), Monoid(mappend, mempty), WriterT(WriterT))
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as LBS (ByteString)
import           Data.List (intercalate)
import           Data.Map as M (Map)
import           Data.String (IsString(..))
import qualified Data.Text.Lazy as T (Text)
import qualified Data.Text as TS (pack, Text, unpack)
import           Data.Typeable (Typeable)
import           Network.HTTP.Types.Header (HeaderName, ResponseHeaders)
import           Network.HTTP.Types.Method (StdMethod)
import           Network.HTTP.Types.Status (Status)
import           Network.Wai (Middleware, Request, Response)
import           Network.Wai.Handler.Warp as Warp (Settings)
import           Network.Wai.Parse (File, Param)
import           Network.WebSockets (Connection)
import           Web.Routes (Site(..))
import           Web.Cookie (CookiesText)

-- | WhebT g s m
--
--   * g -> The global confirgured context (Read-only data shared between threads)
-- 
--   * s -> Handler state for each request.
--
--   * m -> Monad we are transforming
newtype WhebT g s m a = WhebT 
  { runWhebT :: ExceptT WhebError 
                  (ReaderT (HandlerData g s m) (StateT (InternalState s) m)) a 
  } deriving ( Functor, Applicative, Monad, MonadIO )

instance MonadTrans (WhebT g s) where
  lift = WhebT . lift . lift . lift

instance (Monad m) => MonadError WhebError (WhebT g s m) where
    throwError = WhebT . throwError
    catchError (WhebT m) f = WhebT  (catchError m (runWhebT . f))

-- | Writer Monad to build options.
newtype InitM g s m a = InitM { runInitM :: WriterT (InitOptions g s m) IO a}
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Converts a type to a WAI 'Response'
class WhebContent a where
  toResponse :: Status -> ResponseHeaders -> a -> Response

-- | A Wheb response that represents a file.
data WhebFile = WhebFile TS.Text

data HandlerResponse = forall a . WhebContent a => HandlerResponse Status a

-- | Our 'ReaderT' portion of 'WhebT' uses this.
data HandlerData g s m = 
  HandlerData { globalCtx               :: g
              , request                 :: Request
              , postData                :: ([Param], [File LBS.ByteString])
              , routeParams             :: RouteParamList
              , handlerRunTimeSettings  :: CSettings
              , handlerAppRoutes        :: [ Route g s m ]}

-- | Our 'StateT' portion of 'WhebT' uses this.
data InternalState s =
  InternalState { reqState     :: s
                , respHeaders  :: M.Map HeaderName ByteString
                , curCookies   :: CookiesText } 
                
data SettingsValue = forall a. (Typeable a) => MkVal a

data WhebError = Error500 T.Text
               | Error404
               | Error403
               | ErrorStatus Status T.Text
               | RouteParamDoesNotExist
               | URLError TS.Text UrlBuildError
  deriving (Show)

-- | Monoid to use in InitM's WriterT
data InitOptions g s m =
  InitOptions { initRoutes      :: [ Route g s m ]
              , initWhebSockets :: [ SocketRoute g s m ]
              , initSites       :: [ PackedSite g s m ]
              , initCommands    :: [ Command g s m ]
              , initSettings    :: CSettings
              , initWaiMw       :: Middleware
              , initWhebMw      :: [ WhebMiddleware g s m ]
              , initCleanup     :: [ IO () ] }

instance Monoid (InitOptions g s m) where
  mappend (InitOptions a1 ws1 s1 com1 b1 c1 d1 e1) (InitOptions a2 ws2 s2 com2 b2 c2 d2 e2) = 
      InitOptions (a1 <> a2)
                  (ws1 <> ws2)
                  (s1 <> s2)
                  (com1 <> com2)
                  (b1 <> b2)
                  (c2 . c1) 
                  (d1 <> d2) 
                  (e1 <> e2)
  mempty = InitOptions mempty mempty mempty mempty mempty id mempty mempty

-- | The main option datatype for Wheb
data WhebOptions g s m = MonadIO m =>
  WhebOptions { appRoutes           :: [ Route g s m ]
              , appWhebSockets      :: [ SocketRoute g s m ]
              , appSites            :: [ PackedSite g s m ]
              , commands            :: [ Command g s m ]
              , runTimeSettings     :: CSettings
              , warpSettings        :: Warp.Settings
              , startingCtx         :: g -- ^ Global ctx shared between requests
              , startingState       :: InternalState s -- ^ Handler state given each request
              , waiStack            :: Middleware
              , whebMiddlewares     :: [ WhebMiddleware g s m ]
              , defaultErrorHandler :: WhebError -> WhebHandlerT g s m
              , shutdownTVar        :: TVar Bool
              , activeConnections   :: TVar Int
              , cleanupActions      :: [ IO () ] 
              , runToIO             :: (forall a . m a -> IO a)}

type EResponse = Either WhebError Response

type CSettings = M.Map TS.Text SettingsValue
    
type WhebHandler g s      = WhebT g s IO HandlerResponse
type WhebHandlerT g s m   = WhebT g s m HandlerResponse
type WhebMiddleware g s m = WhebT g s m (Maybe HandlerResponse)
type WhebSocket g s m     = Connection -> WhebT g s m ()

-- | A minimal type for WhebT
type MinWheb a = WhebT () () IO a
type MinHandler = MinWheb HandlerResponse
-- | A minimal type for WhebOptions
type MinOpts = WhebOptions () () IO

-- | Command to execute via the command line
data Command g s m = 
  Command { commandName :: TS.Text 
          , commandRun  :: ([TS.Text] -> WhebOptions g s m -> IO ())
          }
              
-- * Routes
data PackedSite g s m = forall a . PackedSite TS.Text (Site a (WhebHandlerT g s m))

type  RouteParamList = [(TS.Text, ParsedChunk)]
type  MethodMatch = StdMethod -> Bool

data ParsedChunk = forall a. (Typeable a, Show a) => MkChunk a

instance Show ParsedChunk where
  show (MkChunk a) = show a

data UrlBuildError = NoParam | ParamTypeMismatch TS.Text | UrlNameNotFound
     deriving (Show) 

-- | A Parser should be able to extract params and regenerate URL from params.
data UrlParser = UrlParser 
    { parseFunc :: ([TS.Text] -> Maybe RouteParamList)
    , genFunc   :: (RouteParamList -> Either UrlBuildError TS.Text) }

data Route g s m = Route 
  { routeName    :: (Maybe TS.Text)
  , routeMethod  :: MethodMatch
  , routeParser  :: UrlParser
  , routeHandler :: (WhebHandlerT g s m) }

data SocketRoute g s m = SocketRoute
  { srouteParser  :: UrlParser
  , srouteHandler :: WhebSocket g s m
  }

data ChunkType = IntChunk | TextChunk
  deriving (Show)

data UrlPat = Chunk TS.Text
            | Composed [UrlPat]
            | FuncChunk 
                { chunkParamName :: TS.Text
                , chunkFunc :: (TS.Text -> Maybe ParsedChunk)
                , chunkType :: ChunkType }

instance Show UrlPat where
  show (Chunk a) = "(Chunk " ++ (TS.unpack a) ++ ")"
  show (Composed a) = intercalate "/" $ fmap show a
  show (FuncChunk pn _ ct) = "(FuncChunk " ++ (TS.unpack pn) ++ " | " ++ (show ct) ++ ")"

instance IsString UrlPat where
  fromString = Chunk . TS.pack
