Wheb
======

The easy Haskell WAI Framework

Objective
---------

The primary goal of the Wheb framework is to extend the functionality of the base WAI library as well as provide an easy entry point into Haskell web servers. Other servers such as Snap and Yesod make use of a number of extensions and Template Haskell. While TH is powerful in allowing you to build compile time type safe urls, it is another hurdle for someone starting out in Haskell to learn before they can get started. While Yesod and others have non-TH versions of their libraries, it just adds fragmentation within the documenation and tutorials about how to effectively use it.

So, I built the Wheb framework with the explicit goal that Template Haskell not be included in any part of the core server.

Other libraries feature transformers to roll your own Reader and State based applicaiton Monads, but it would be nice if they were built in. Practically every server will have a global read-only context that shares resources between threads and a request state that can change during request processing. Having these resources built in allows for plugins that can always expect those resources to be there.

Features
--------

Currently Wheb is still very early in development. I have included some features that I hope will cover most use cases.


#### Easy Setup.
Here is a Crunchy server:

```haskell
import           Web.Wheb
import           Data.Text.Lazy (pack)

main :: IO ()
main = do
  opts <- generateOptions $ addGET (pack ".") rootPat $ (text (pack "Hi!"))
  runWhebServer (opts :: MinOpts)
```

Route handlers can be simple:

```haskell
handleSimple :: T.Text -> WhebHandler GlobalApp RequestState
handleSimple t = html $ "<h1>" <> t <> "</h1>"
```

Or add some complexity...

```haskell
homePage :: WhebHandler GlobalApp RequestState
homePage = do
  -- | Keep track of sessions...
  v <- getSessionValue "has-visted"
  setSessionValue "has-visted" "True"
  case v of
    Just _  -> do
        url  <- getRoute "blog_txt" [("slug", MkChunk ("hey" :: T.Text))]
        html $ "<h1>Welcome back!</h1><a href=\"" <> url <> "\">Go to blog</a>"
    Nothing -> do
        url  <- getRoute "faq" []
        html $ "<h1>Hello Stranger!</h1><a href=\"" <> url <> "\">FAQ</a>"
```

As you scale your code base, the core simplicity remains.

```haskell
main :: IO ()
main = do
  opts <- generateOptions $ do
      -- | Add standard WAI middlware
      addWAIMiddleware logStdoutDev
      
      -- | Add Auth middlware for current user.
      addCrunchyMiddleware authMiddleware
      
      -- | Add your application routes...
      addGET "root" rootPat homePage
      addGET "faq" "faq" $  handleSimple "FAQ"
      addPOST "post_store" ("post" </> "store") handlePOST
      
      -- | Auth Handlers.
      addGET  "current"  "current"  handleCurrentUser
      addPOST "register" "register" handleRegister
      addPOST "login"    "login"    handleLogin
      
      -- | Overloaded URLs
      addGET "blog_int"  ("blog" </> (grabInt "pk")) $ handleSimple "Number"
      addGET  "blog_txt" ("blog" </> (grabText "slug")) $ 
            (getRouteParam "slug") >>= (handleSimple . fromJust)
            
      -- | Add sub-init script that is in a sub-app to keep things tidy
      addBlogPaths
      
      -- | Initialize any backends.
      sess <- initSessionMemory
      auth <- initAuthMemory
      
      -- | Return your new global context.
      return (GlobalApp sess auth)
      
  runCrunchyServer opts
```


#### URLs
Crunchy uses named dynamically typed URLs. While this means you won't get compile-time checking of your URLs, it gives you some form of type safety beyond simple text. 

```haskell
-- | This URL will match /blog/1 but not /blog/foo
url = compilePat ("blog" </> (grabInt "pk"))
-- | Output will be Right "/blog/3/"
generateUrl url [("pk", MkChunk 3)]
-- | Output will be Left (ParamTypeMismatch "pk")
generateUrl url [("pk", MkChunk 'A')]
```

Also, because they are named you can generate one of your URLs based on its name and parameters.

```haskell
url <- getRoute "blog_txt" [("slug", MkChunk ("hey" :: T.Text))]
```

#### Middlewares
Crunchy supports WAI and its own CrunchyMiddlwares. CrunchyMiddlwares allow you to change the state before it reaches your handler. It also allows you to return a response to intercept requests.

The included auth middlware makes use of the ability to change state to set the current user before each Handler.

#### Debugging

You can run handlers and debug directly without a server:

```haskell
main :: IO ()
main = do
  opts <- generateOptions $ do
      addWhebMiddleware authMiddleware
      addGET "blog_int"  ("blog" </> (grabInt "pk")) $ handleSimple "Number"
      sess <- initSessionMemory
      auth <- initAuthMemory
      return (GlobalApp sess auth)
  
  -- | Ability to easily run your handlers w/o a server.
  hResult <- debugHandlerIO opts $ handleSimple "Hello from console!"
  either print (\r -> (showResponseBody r) >>= print) hResult
  
  -- | Or simply debug some stuff.
  debugHandlerIO opts $ do
    liftIO $ putStrLn "Testing..."
    liftIO $ putStrLn "\n\nRoutes..."
    (liftIO . print) =<< getRoute' "blog_int" [("pk", MkChunk (3 :: Int))]
    
    liftIO $ putStrLn "\n\nUsers auth..."
    (liftIO . print) =<< getCurrentUser
    (liftIO . print) =<< register "Joe" "123"
    (liftIO . print) =<< login "Joe" "123"
    (liftIO . print) =<< getCurrentUser
```

#### Plugins
There are 2 proof-of-concept plugins, Auth and Sessions. Both are implemented to be abstract interfaces for different backends. Included is a Memory backend that destroys values on server shutdown. Other backends to allow data persistence can be easily added.


#### Speed
When Wheb is deployed, it uses warp. This means you get great performance right away with almost zero configuration.

These benchmarks were taken on a base configuration linode server...

```
```