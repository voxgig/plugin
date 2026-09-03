-- | Dynamic resolution (§10.2) — name to candidate module ids.
--
-- PURE. It returns the ids a host WOULD try, in order; it does not load
-- anything. That separation is what lets the corpus pin resolution in
-- every language including those with no dynamic loading at all —
-- haskell among them — and it is why §15.4 puts real module loading in
-- per-port integration tests rather than here.
--
-- Pure in the Haskell sense too: it cannot raise, so it is not 'IO'.

module Resolve (resolveCandidates, resolveFrom) where

import Value

pushUniq :: [String] -> String -> [String]
pushUniq acc x = if x `elem` acc then acc else acc ++ [x]

defaultPrefix :: [String]
defaultPrefix = ["@voxgig/plugin-", "voxgig-plugin-", "plugin-", ""]

resolveCandidates :: Value -> Value -> Value
resolveCandidates name sources
  -- A SCOPED NAME RESOLVES VERBATIM ONLY (§10.2). @\@acme\/thing@ is
  -- already a package id; prefixing it produces
  -- @\@voxgig\/plugin-\@acme\/thing@, which is not a thing that can
  -- exist.
  | take 1 n == "@" = VList [VStr n]
  | not given = VList (map VStr (foldl pushUniq [] [p ++ n | p <- defaultPrefix]))
  | otherwise = VList (map VStr (foldl fromSource [] (vitems sources)))
  where
    n = if isStr name then asStr name else ""
    given = isList sources && vlen sources > 0
    fromSource acc src
      | kind == "module" =
          if isList prefix && vlen prefix > 0
            then foldl pushUniq acc [asStr p ++ n | p <- vitems prefix]
            else pushUniq acc n
      -- Trailing slashes are trimmed, so @lib\/@ and @lib@ give one id
      -- rather than two spellings of it.
      | kind == "path" = pushUniq acc (trimSlash (asStr (vget src "dir")) ++ "/" ++ n)
      | otherwise = acc
      where
        kind = asStr (vget src "kind")
        prefix = vget src "prefix"
    trimSlash = reverse . dropWhile (== '/') . reverse

-- | A MODULE PATH IS NOT A NAME (§10.2). The ref grammar starts a name
-- with a letter or @\@@, so @.\/local\/thing@ is not a ref and never
-- reaches candidate generation — seneca allows a path where a plugin
-- name goes, and this design deliberately does not, because a ref is an
-- ADDRESS WITHIN A HOST and a path is a LOCATION ON A DISK.
--
-- Loading from an explicit location bypasses candidate generation
-- entirely: @from@ is passed to the resolver verbatim.
resolveFrom :: Value -> Value
resolveFrom from = VList [if isNull from then VNull else from]
