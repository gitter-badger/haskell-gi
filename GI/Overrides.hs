{-# LANGUAGE OverloadedStrings, ViewPatterns #-}
module GI.Overrides
    ( Overrides -- ^ We export just the type, but no constructors.
    , parseOverridesFile
    , loadFilteredAPI
    ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad.Except
import Control.Monad.State
import Control.Monad.Writer

import Data.Maybe (fromMaybe)
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.Text as T
import Data.Text (Text)

import GI.API

data Overrides = Overrides {
      -- | Prefix for constants in a given namespace, if not given the
      -- "_" string will be used.
      constantPrefix :: M.Map String String,
      -- | Ignored elements of a given API.
      ignoredElems   :: M.Map Name (S.Set String),
      -- | Ignored APIs (all elements in this API will just be discarded).
      ignoredAPIs    :: S.Set Name,
      -- | Structs for which accessors should not be auto-generated.
      sealedStructs  :: S.Set Name
}

-- | Construct the generic config for a module.
defaultOverrides :: Overrides
defaultOverrides = Overrides {
              constantPrefix = M.empty,
              ignoredElems   = M.empty,
              ignoredAPIs    = S.empty,
              sealedStructs  = S.empty }

-- | There is a sensible notion of zero and addition of Overridess,
-- encode this so that we can view the parser as a writer monad of
-- configs.
instance Monoid Overrides where
    mempty = defaultOverrides
    mappend a b = Overrides {
                         constantPrefix = constantPrefix a <> constantPrefix b,
                         ignoredAPIs = ignoredAPIs a <> ignoredAPIs b,
                         sealedStructs = sealedStructs a <> sealedStructs b,
                         ignoredElems = M.unionWith S.union (ignoredElems a)
                                        (ignoredElems b)
                       }

-- | We have a bit of context (the current namespace), and can fail,
-- encode this in a monad.
type Parser = WriterT Overrides (StateT (Maybe String) (Except Text)) ()

-- | Parse the given config file (as a set of lines) for a given
-- introspection namespace, filling in the configuration as needed. In
-- case the parsing fails we return a description of the error
-- instead.
parseOverridesFile :: [Text] -> Either Text Overrides
parseOverridesFile ls = runExcept $ flip evalStateT Nothing $ execWriterT $
                                    mapM (parseOneLine . T.strip) ls

-- | Parse a single line of the config file, modifying the
-- configuration as appropriate.
parseOneLine :: Text -> Parser
-- Empty lines
parseOneLine line | T.null line = return ()
-- Comments
parseOneLine (T.stripPrefix "#" -> Just _) = return ()
parseOneLine (T.stripPrefix "namespace " -> Just ns) =
    (put . Just . T.unpack . T.strip) ns
parseOneLine (T.stripPrefix "ignore " -> Just ign) = get >>= parseIgnore ign
parseOneLine (T.stripPrefix "constantPrefix " -> Just p) = get >>= parseConstP p
parseOneLine (T.stripPrefix "seal " -> Just s) = get >>= parseSeal s
parseOneLine l = throwError $ "Could not understand \"" <> l <> "\"."

-- | Ignored elements.
parseIgnore :: Text -> Maybe String -> Parser
parseIgnore _ Nothing =
    throwError "'ignore' requires a namespace to be defined first."
parseIgnore (T.words -> [T.splitOn "." -> [api,elem]]) (Just ns) =
    tell $ defaultOverrides {ignoredElems = M.singleton (Name ns (T.unpack api))
                                         (S.singleton $ T.unpack elem)}
parseIgnore (T.words -> [T.splitOn "." -> [api]]) (Just ns) =
    tell $ defaultOverrides {ignoredAPIs = S.singleton (Name ns (T.unpack api))}
parseIgnore ignore _ =
    throwError ("Ignore syntax is of the form \"ignore API.elem\" with '.elem' optional.\nGot \"ignore " <> ignore <> "\" instead.")

-- | Prefix for constants.
parseConstP :: Text -> Maybe String -> Parser
parseConstP _ Nothing = throwError "'constantPrefix' requires a namespace to be defined first. "
parseConstP (T.words -> [p]) (Just ns) = tell $
    defaultOverrides {constantPrefix = M.singleton ns (T.unpack p)}
parseConstP prefix _ =
    throwError ("constantPrefix syntax is of the form \"constantPrefix prefix\".\nGot \"constantPrefix " <> prefix <> "\" instead.")

-- | Sealed structures.
parseSeal :: Text -> Maybe String -> Parser
parseSeal _ Nothing = throwError "'seal' requires a namespace to be defined first."
parseSeal (T.words -> [s]) (Just ns) = tell $
    defaultOverrides {sealedStructs = S.singleton (Name ns (T.unpack s))}
parseSeal seal _ =
    throwError ("seal syntax is of the form \"seal name\".\nGot \"seal "
                <> seal <> "\" instead.")

-- | Filter a set of named objects based on a lookup list of names to
-- ignore.
filterNamed :: [(Name, a)] -> S.Set String -> [(Name, a)]
filterNamed set ignores = filter ((`S.notMember` ignores) . name . fst) set

-- | Filter one API according to the given config.
filterOneAPI :: Overrides -> (Name, API, Maybe (S.Set String)) -> (Name, API)
filterOneAPI ovs (Name ns n, APIConst c, _) =
    (Name ns (prefix ++ n), APIConst c)
    where prefix = fromMaybe "_" $ M.lookup ns (constantPrefix ovs)
filterOneAPI ovs (n, APIStruct s, maybeIgnores) =
    (n, APIStruct s {structMethods = maybe (structMethods s)
                                     (filterNamed (structMethods s))
                                     maybeIgnores,
                     structFields = if n `S.member` sealedStructs ovs
                                    then []
                                    else structFields s})
-- The rest only apply if there are ignores.
filterOneAPI _ (n, api, Nothing) = (n, api)
filterOneAPI _ (n, APIObject o, Just ignores) =
    (n, APIObject o {objMethods = filterNamed (objMethods o) ignores,
                     objSignals = filter ((`S.notMember` ignores) . sigName)
                                  (objSignals o)
                    })
filterOneAPI _ (n, APIInterface i, Just ignores) =
    (n, APIInterface i {ifMethods = filterNamed (ifMethods i) ignores,
                        ifSignals = filter ((`S.notMember` ignores) . sigName)
                                    (ifSignals i)
                       })
filterOneAPI _ (n, APIUnion u, Just ignores) =
    (n, APIUnion u {unionMethods = filterNamed (unionMethods u) ignores})
filterOneAPI _ (n, api, _) = (n, api)

-- | Given a list of APIs modify them according to the given config.
filterAPIs :: Overrides -> [(Name, API)] -> [(Name, API)]
filterAPIs ovs apis = map (filterOneAPI ovs . fetchIgnores) filtered
    where filtered = filter ((`S.notMember` ignoredAPIs ovs) . fst) apis
          fetchIgnores (n, api) = (n, api, M.lookup n (ignoredElems ovs))

-- | Load the given API using the given list of overrides.
loadFilteredAPI :: Bool -> Overrides -> String -> IO [(Name, API)]
loadFilteredAPI verbose ovs name = filterAPIs ovs <$> loadAPI verbose name
