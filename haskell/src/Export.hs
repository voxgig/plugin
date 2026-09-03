-- | Exports (§11).
--
-- THE UNQUALIFIED ALIAS IS THE INTERESTING PART. @retry\/client@
-- resolves to the UNTAGGED instance if one exists; if not, and exactly
-- one tagged instance exports that key, it resolves to that one; if two
-- do, it is @plugin_export_ambiguous@ — deliberately diverging from
-- seneca's silent last-wins, because with multi-instance as a headline
-- feature an ambiguous alias is a defect waiting for production.

module Export (resolveExport) where

import Data.List (sort)
import Ref
import Types
import Value

-- | Answers 'Nothing' for "no such export", which is not an error —
-- @export\/missing@ pins that, and is why the answer is a 'Maybe'
-- rather than a null Value.
resolveExport :: Value -> Value -> IO (Maybe Value)
resolveExport spec exported =
  case break (== '/') s of
    (_, []) ->
      raise "plugin_export_ambiguous" ("export spec needs a key: " ++ s)
        (details1 "spec" (VStr s))
    (headS, _ : key) -> pick headS key
  where
    s = if isStr spec then asStr spec else ""

    pick headS key
      -- A fully qualified ref: exactly one answer or none.
      | Just want <- tryRef headS
      , (e : _) <- [x | x <- vitems exported, asStr (vget x "ref") == want, asStr (vget x "key") == key] =
          return (Just (vget e "value"))
      -- An alias: the NAME, not a ref. Look at every instance of it.
      | null byname = return Nothing
      -- The untagged instance wins outright when there is one.
      | (e : _) <- [x | x <- byname, '$' `notElem` asStr (vget x "ref")] =
          return (Just (vget e "value"))
      | [e] <- byname = return (Just (vget e "value"))
      | otherwise =
          raise "plugin_export_ambiguous"
            ("alias " ++ s ++ " matches " ++ show (length byname) ++ " instances: " ++ commas refs)
            (vset (vset (VMap []) "spec" (VStr s)) "refs" (VList (map VStr refs)))
      where
        byname =
          [ x | x <- vitems exported
          , refName (asStr (vget x "ref")) == headS
          , asStr (vget x "key") == key ]
        refs = sort [asStr (vget x "ref") | x <- byname]

commas :: [String] -> String
commas [] = ""
commas [x] = x
commas (x : xs) = x ++ ", " ++ commas xs
