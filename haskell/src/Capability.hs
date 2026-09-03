-- | Capabilities (§11.1).
--
-- A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
-- dependency on something that can do the job, and which instance is
-- doing it is exactly the configuration detail a plugin must not care
-- about. (§11.1 makes one narrow exception for a ref, and "Host"
-- implements it; the ranking here is capabilities only.)
--
-- But A BINDING IS TO AN INSTANCE, not to a capability, which is what
-- decides behaviour when the bound provider leaves while another match
-- remains.

module Capability
  ( resolveCapability, capMatches, capMatchValue
  ) where

import Control.Exception (catch)
import Data.List (sortBy)
import Types
import Value
import Version

-- | PARTIAL MATCH, RECURSING INTO MAPS (§11.1). THIS FUNCTION IS WHAT
-- "EVERY LEAF" MEANS, and an earlier draft of the canonical did not
-- have it: the check was a scalar compare, which for any compound value
-- is reference identity in JavaScript. A requirement and a capability
-- are declared in different places and are never the same object, so
-- @match: {limits: {max: 5}}@ could not be satisfied by ANY provider —
-- including one declaring exactly that. Invisible while every corpus
-- entry is scalar, which is why the go port found it and P2 did not.
--
-- A LIST IS COMPARED LEAF-WISE AT THE SAME LENGTH, not as a subset —
-- "the first two of your three regions" is not something @match@ can
-- say.
capMatchValue :: Value -> Value -> Bool
capMatchValue want got
  | isMap want =
      isMap got
        && all (\k -> vhas got k && capMatchValue (vget want k) (vget got k)) (vkeys want)
  | isList want =
      isList got && vlen want == vlen got
        && and (zipWith capMatchValue (vitems want) (vitems got))
  | otherwise = same want got

capMatches :: Value -> Value -> IO Bool
capMatches req prov
  | not (same (vget req "name") (vget prov "name")) = return False
  | otherwise = do
      versionok <-
        if isNull range
          then return True
          else
            if isNull version then return False else satisfiesQ version range
      if not versionok
        then return False
        else
          -- @match@ is checked against the provider's @attrs@, key by
          -- key. A key the provider does not carry is a MISS, not a
          -- pass: a requirement asking for @transactional: true@ must
          -- not be satisfied by a provider that never said.
          return $
            isNull m
              || all
                (\k -> vhas attrs k && capMatchValue (vget m k) (vget attrs k))
                (vkeys m)
  where
    range = vget req "range"
    version = vget prov "version"
    m = vget req "match"
    attrs = let a = vget prov "attrs" in if isNull a then VMap [] else a

-- | The rank key for one candidate: (version rank, priority, pos).
-- Ordering is a TOTAL rank on purpose: without one, "any provider
-- satisfies" is true of the GRAPH and useless to the PLUGIN — two ports
-- could bind different @store@ instances, both resolve green, and
-- behave differently, which is precisely the divergence a shared corpus
-- exists to catch.
rankKey :: Value -> IO (Int, [Double], Double, Double)
rankKey c = do
  parsed <-
    if isNull v
      then return []
      else
        (do p <- parseVersion v; return [negate (asNum (vat p i)) | i <- [0 .. 2]])
          `catch` \e -> let _ = (e :: PluginError) in return [0, 0, 0]
  return (if isNull v then 1 else 0, parsed, prio, asNum (vget c "pos"))
  where
    p' = vget c "provides"
    v = vget p' "version"
    prio = let x = vget p' "priority" in if isNum x then asNum x else 0

-- | Rank the matching providers best-first: highest @version@, then
-- LOWEST @priority@ (default 0), then declaration position @pos@
-- ascending.
resolveCapability :: Value -> Value -> IO Value
resolveCapability req candidates = do
  hits <- filterM' (\c -> capMatches req (vget c "provides")) (vitems candidates)
  keyed <- mapM (\c -> do k <- rankKey c; return (k, c)) hits
  -- A version beats none, so the absent-version flag sorts first;
  -- HIGHEST version first, which is why 'rankKey' negates; then LOWEST
  -- priority; then `pos`, which is unique, so the sort is a TOTAL order
  -- and stability is not relied on.
  return (VList (map snd (sortBy (\a b -> compare (fst a) (fst b)) keyed)))

filterM' :: (a -> IO Bool) -> [a] -> IO [a]
filterM' _ [] = return []
filterM' p (x : xs) = do
  keep <- p x
  rest <- filterM' p xs
  return (if keep then x : rest else rest)
