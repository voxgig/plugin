-- | The definition catalog (§10.1).
--
-- A definition is registered once and may back many instances. Option
-- shapes are validated AT REGISTRATION, not when a document happens to
-- exercise a key — so a malformed shape fails once, and in the same
-- place everywhere (§9.4). @declare\/shape@ pins that timing.

module Catalog (makeCatalog, catalogAdd, catalogGet, catalogHas, catalogNames, callbackFor) where

import Config (checkShape)
import Data.IORef
import Data.List (sort)
import Defs
import Ref (checkname)
import Types
import Value

makeCatalog :: IO Catalog
makeCatalog = newIORef []

catalogAdd :: Catalog -> Definition -> IO ()
catalogAdd c def
  | not (checkname (VStr (dName def))) =
      raise "plugin_definition_name" ("invalid definition name: " ++ dName def) (VMap [])
  | otherwise = do
      -- Validate the shape HERE. Deferring it to resolution time means
      -- a malformed shape surfaces at a different moment in every host
      -- that loads it, which is the divergence the stated domain exists
      -- to prevent.
      if isNull (dShape def) then return () else checkShape (dShape def)
      modifyIORef' c upsert
  where
    upsert defs
      | any ((== dName def) . fst) defs =
          map (\(k, d) -> if k == dName def then (k, def) else (k, d)) defs
      | otherwise = defs ++ [(dName def, def)]

catalogGet :: Catalog -> String -> IO (Maybe Definition)
catalogGet c name = lookup name <$> readIORef c

catalogHas :: Catalog -> String -> IO Bool
catalogHas c name = maybe False (const True) <$> catalogGet c name

catalogNames :: Catalog -> IO Value
catalogNames c = (VList . map VStr . sort . map fst) <$> readIORef c

-- | The callback for a phase, by the name the log and the corpus use.
callbackFor :: Definition -> String -> Maybe (Inst -> IO ())
callbackFor d "define" = dDefine d
callbackFor d "activate" = dActivate d
callbackFor d "deactivate" = dDeactivate d
callbackFor d "close" = dClose d
callbackFor _ _ = Nothing
