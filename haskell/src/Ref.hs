-- | Identity: name+tag, written @name$tag@ (§4).
--
-- The four pure functions, and the whole of what @ref@ pins. They are
-- the first thing a new port implements and the first corpus section it
-- passes.
--
-- 'checkname' and 'checktag' are pure because they answer 'Bool';
-- 'parseRef', 'formatRef' and 'canonRef' are 'IO' because they raise.
-- See "Types" for why that split is not a matter of taste here.

module Ref
  ( checkname, checktag
  , parseRef, formatRef, canonRef, canonRefS
  , tryRef, canon, refName
  ) where

import Types
import Value

maxRef :: Int
maxRef = 1024

isNameHead :: Char -> Bool
isNameHead c = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '@'

isNameBody :: Char -> Bool
isNameBody c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c `elem` ".~_-/"

isTagChar :: Char -> Bool
isTagChar c =
  (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
    || c `elem` ".~_-"

namely :: String -> Bool
namely [] = False
namely s@(c : rest) =
  length s <= maxRef && isNameHead c && all isNameBody rest

-- | The empty tag is an ordinary tag (§4 rule 2). The single-instance
-- case writes no tag and never learns tags exist.
tagly :: String -> Bool
tagly [] = True
tagly s = length s <= maxRef && all isTagChar s

-- | A non-string is not a name. Every port has to answer this the same
-- way, and @ref\/name@ pins it for numbers, nulls and maps alike.
checkname :: Value -> Bool
checkname v = isStr v && namely (asStr v)

-- | The asymmetry with a name is deliberate: a tag MAY start with a
-- digit because auto-tagging assigns integer tags (@stripe$1@), and a
-- tag admits neither @\@@ nor @\/@ because a name is a package
-- specifier and a tag is not.
checktag :: Value -> Bool
checktag v = isStr v && tagly (asStr v)

-- | Split on the FIRST @$@. Nothing in the grammar decides this — @$@
-- is in neither character class — so the corpus is the arbiter (§4 rule
-- 5), and it picks the split that blames the part actually at fault:
-- @a$b$c@ is a good name with a bad tag, not the reverse.
splitRef :: String -> (String, String)
splitRef s = case break (== '$') s of
  (n, '$' : t) -> (n, t)
  (n, _) -> (n, "")

parseRef :: Value -> IO Value
parseRef str
  | not (isStr str) = raise "plugin_bad_name" "ref must be a string" (VMap [])
  | not (namely name) =
      raise "plugin_bad_name" ("invalid plugin name: " ++ name)
        (details1 "name" (VStr name))
  | not (tagly tag) =
      raise "plugin_bad_tag" ("invalid plugin tag: " ++ tag)
        (details2 "name" (VStr name) "tag" (VStr tag))
  | otherwise = return (vset (vset (VMap []) "name" (VStr name)) "tag" (VStr tag))
  where
    (name, tag) = splitRef (asStr str)

-- | An empty tag NEVER writes the separator, which is the half of
-- canonicalization 'formatRef' owns: parse tolerates @stripe$@, format
-- never produces it, so a round trip is idempotent.
formatRef :: Value -> Value -> IO String
formatRef name tag
  | not (checkname name) =
      raise "plugin_bad_name" ("invalid plugin name: " ++ shown)
        (details1 "name" (if isNull name then VNull else name))
  | not tagok || not (tagly t) =
      raise "plugin_bad_tag" ("invalid plugin tag: " ++ t)
        (details2 "name" name "tag" (if isNull tag then VStr "" else tag))
  | null t = return (asStr name)
  | otherwise = return (asStr name ++ "$" ++ t)
  where
    shown = if isStr name then asStr name else ""
    tagok = isNull tag || isStr tag
    t = if isStr tag then asStr tag else ""

-- | The canonical spelling. §4 rule 5: canonicalize before comparison.
canonRef :: Value -> IO String
canonRef str = do
  r <- parseRef str
  formatRef (vget r "name") (vget r "tag")

canonRefS :: String -> IO String
canonRefS = canonRef . VStr

-- | The canonical ref this string denotes, or 'Nothing' if it denotes
-- none — the TOLERANT half of 'canonRef', and the one a requirement
-- name needs (§11.1). Capability names are free-form, so @2fa@ is a
-- good one and no ref could be called that; 'canonRef' RAISES on those,
-- and asking it "is this a ref?" made a legal document kill the host.
--
-- A 'Maybe', so a caller cannot mistake "not a ref" for "the empty
-- ref" — and pure, because it answers rather than raises.
tryRef :: String -> Maybe String
tryRef s
  | not (namely name) || not (tagly tag) = Nothing
  | null tag = Just name
  | otherwise = Just (name ++ "$" ++ tag)
  where
    (name, tag) = splitRef s

-- | 'canonRef' for internal callers that want the input back unchanged
-- when it is not well formed. NEVER use where a bad ref must be
-- reported — the corpus pins @plugin_bad_name@ at every public entry.
canon :: String -> String
canon s = maybe s id (tryRef s)

-- | The name half, for internal callers that only compare.
refName :: String -> String
refName s = if namely n then n else s
  where
    (n, _) = splitRef s
