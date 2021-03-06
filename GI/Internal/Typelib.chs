module GI.Internal.Typelib
  ( getSearchPath
  , prependSearchPath
  , getLoadedNamespaces
  , getInfos
  , getSharedLibraries
  , findByGType
  , load
  )
where

#if __GLASGOW_HASKELL__ < 710
import Control.Applicative ((<$>))
#endif
import Control.Monad (when)

import Foreign
import Foreign.C

import GI.Internal.Types
import GI.Util
import GI.Utils.BasicTypes (GType(..), CGType)

import GI.Utils.GError
import GI.Utils.BasicConversions (unpackGSList)

#include <girepository.h>

{#context prefix="g_irepository"#}

{# pointer *GITypelib as Typelib newtype #}
unTypelib :: Typelib -> Ptr Typelib
unTypelib (Typelib p) = p

{# pointer *GIRepository as Repository newtype #}

nullRepository = Repository nullPtr

prependSearchPath :: FilePath -> IO ()
prependSearchPath path = do
  withCString path $ \pathPtr ->
      {# call prepend_search_path #} pathPtr
  newSearchPath <- getSearchPath
  putStrLn $ "New search path: " ++ show newSearchPath

getSearchPath :: IO [FilePath]
getSearchPath = do
    paths <- {# call unsafe get_search_path #}
    pathPtrs <- unpackGSList (castPtr paths)
    mapM peekCString pathPtrs

mapCStrings f ptr = do
  str <- peek ptr
  if str == nullPtr
      then return []
      else do
          -- XXX: O(n) in size
          x <- f str
          xs <- mapCStrings f $ ptr `plusPtr` sizeOf (undefined :: Ptr CString)
          return $ x : xs

peekCStrings = mapCStrings peekCString

getLoadedNamespaces :: IO [String]
getLoadedNamespaces = do
    nsPtrs <- {# call unsafe get_loaded_namespaces #} nullRepository
    nss <- peekCStrings nsPtrs
    _ <- mapCStrings free nsPtrs
    free nsPtrs
    return nss

getInfos :: Typelib -> IO [BaseInfo]
getInfos typelib = do
    nsPtr <- {# call unsafe g_typelib_get_namespace #} typelib
    map (BaseInfo <$> castPtr) <$> getList
        ({# call unsafe get_n_infos #} nullRepository)
        ({# call unsafe get_info #} nullRepository)
        nsPtr

-- _require()'s return is annotated as 'transfer none'. I'm assuming
-- that we don't need to ref this because it's never going to be freed,
-- though, so we're fine.
require :: String -> Maybe String -> Ptr (Ptr ()) -> IO Typelib
require namespace version gError =
    withCString namespace $ \nsPtr ->
    maybeWithCString version $ \versionPtr ->
        {# call unsafe require #} nullRepository nsPtr versionPtr 0 gError

-- Although the C function is called "_get_shared_library" and the
-- documentation suggests that a single library name is returned, is
-- actually returns a comma separated list. Thanks, libgirepository!
getSharedLibraries :: String -> IO (Maybe [String])
getSharedLibraries name =
    withCString name $ \namePtr -> do
        _ <- propagateGError $ \gError ->
          require name Nothing gError
        path <- {# call get_shared_library #} nullRepository namePtr
        if path == nullPtr
          then return Nothing
          else Just <$> split ',' <$> peekCString path

load :: String -> Maybe String -> Bool -> IO Typelib
load namespace version verbose =
    propagateGError $ \gError -> do
        typelib <- require namespace version gError
        when (unTypelib typelib /= nullPtr) $ do
            path <- peekCString =<< (withCString namespace $ \nsPtr ->
                    {# call get_typelib_path #} nullRepository nsPtr)
            when verbose $
                 putStrLn $ "Loading typelib: " ++ path
            _ <- {# call unsafe load_typelib #} nullRepository typelib 0 gError
            return ()
        return typelib

foreign import ccall unsafe "g_irepository_find_by_gtype" find_by_gtype ::
    Ptr Repository -> CGType -> IO (Ptr BaseInfo)

findByGType :: GType -> IO (Maybe BaseInfo)
findByGType (GType gtype) = do
  ptr <- find_by_gtype nullPtr gtype
  if ptr /= nullPtr
  then return $ (Just . BaseInfo . castPtr) ptr
  else return Nothing
