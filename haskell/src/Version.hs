-- | Versions and ranges (§11.2).
--
-- TWO FIELDS AND ONE PREDICATE. A capability declares @version@, a
-- concrete version. A requirement declares @range@. A requirement is
-- satisfied when the names match, the @match@ passes, and the
-- provider's @version@ falls inside the requirement's @range@. That is
-- the whole rule — there is no third field and no second comparison.

module Version
  ( parseRange, parseVersion, satisfies, satisfiesQ, verCmp
  ) where

import Control.Exception (catch)
import Types
import Value

-- | A COMPONENT IS BOUNDED, like a ref is (§4's 1024).
--
-- The grammar admits an unbounded digit sequence, and every language
-- then disagrees about what happens past its integer range: JavaScript
-- silently loses precision, Go's Atoi errors (and a port ignoring that
-- gets 0), C overflows, Python is exact — and Haskell's 'Integer' is
-- unbounded, which is a THIRD answer. @satisfies "0"
-- "9223372036854775808"@ was false in the canonical and true in go,
-- from the same corpus.
--
-- 2^31-1 because every port has a signed 32-bit integer, and no real
-- version has ever needed more. Stated rather than left to arithmetic
-- nobody agrees on. Found by review of the go port.
componentMax :: Integer
componentMax = 2147483647

-- | @^(\\d+)(?:\\.(\\d+))?(?:\\.(\\d+))?$@, by hand: three components,
-- digits only, no leading sign, no empty component. Written out rather
-- than handed to a regex because the bound above has to be checked per
-- component anyway.
--
-- Answers @Nothing@ for "not a version", or the three parts and whether
-- any overflowed.
parse3 :: String -> Maybe ([Integer], Bool)
parse3 "" = Nothing
parse3 s = go s (0 :: Int) []
  where
    go :: String -> Int -> [Integer] -> Maybe ([Integer], Bool)
    go rest part acc
      | part >= 3 = if null rest then Just (pad (reverse acc), overflowed acc) else Nothing
      | null rest = if part > 0 then Just (pad (reverse acc), overflowed acc) else Nothing
      | otherwise =
          let rest' = if part > 0 then (case rest of ('.' : r) -> Just r; _ -> Nothing) else Just rest
          in case rest' of
               Nothing -> Nothing
               Just r ->
                 let (ds, more) = span (\c -> c >= '0' && c <= '9') r
                 in if null ds then Nothing else go more (part + 1) (read ds : acc)
    pad xs = take 3 (xs ++ [0, 0, 0])
    overflowed = any (> componentMax)

triple :: [Integer] -> Value
triple ns = VList [VNum (fromIntegral n) | n <- ns]

parseRange :: Value -> IO Value
parseRange range
  | not (isStr range) || null (asStr range) =
      raise "plugin_bad_range" ("invalid range: " ++ shown)
        (details1 "range" (if isNull range then VNull else range))
  | otherwise = case parse3 body of
      Nothing -> raise "plugin_bad_range" ("invalid range: " ++ s) (details1 "range" range)
      Just (_, True) ->
        raise "plugin_bad_range" ("version component out of range in " ++ s)
          (details1 "range" range)
      Just (n, False) ->
        let lo = n
            -- Two forms and no more (§11.2):
            --   '2.1'   >= 2.1.0 and < 3.0.0
            --   '~2.1'  >= 2.1.0 and < 2.2.0
            hi = if tilde then [n !! 0, n !! 1 + 1, 0] else [n !! 0 + 1, 0, 0]
        in return (vset (vset (VMap []) "lo" (triple lo)) "hi" (triple hi))
  where
    shown = if isStr range then asStr range else ""
    s = asStr range
    tilde = take 1 s == "~"
    body = if tilde then drop 1 s else s

parseVersion :: Value -> IO Value
parseVersion version
  | not (isStr version) =
      raise "plugin_bad_range" "invalid version"
        (details1 "version" (if isNull version then VNull else version))
  | otherwise = case parse3 s of
      -- @plugin_bad_range@ either way — the same code the rest of the
      -- grammar's failures use, because "this is not a version I can
      -- compare" is one fact however it went wrong.
      Nothing -> raise "plugin_bad_range" ("invalid version: " ++ s) (details1 "version" version)
      Just (_, True) ->
        raise "plugin_bad_range" ("version component out of range in " ++ s)
          (details1 "version" version)
      Just (n, False) -> return (triple n)
  where
    s = asStr version

verCmp :: Value -> Value -> Ordering
verCmp a b = mconcat [compare (asNum (vat a i)) (asNum (vat b i)) | i <- [0 .. 2]]

-- | The one satisfaction predicate: lo <= version < hi.
satisfies :: Value -> Value -> IO Bool
satisfies version range = do
  v <- parseVersion version
  r <- parseRange range
  return (verCmp v (vget r "lo") /= LT && verCmp v (vget r "hi") == LT)

-- | The same, tolerant of a missing version — a bare ref carries none,
-- so @Graph@ and @Depend@ ask this rather than raising.
satisfiesQ :: Value -> Value -> IO Bool
satisfiesQ version range =
  satisfies version range `catch` \e -> let _ = (e :: PluginError) in return False
