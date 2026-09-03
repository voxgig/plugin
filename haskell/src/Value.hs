-- | The dynamic value, and the JSON reader that fills it (§16).
--
-- NO DEPENDENCIES, not even a JSON library: §16 permits exactly one
-- runtime dependency (voxgig/struct) and Haskell has no port of it, so
-- the corpus JSON is parsed here. A package graph is also a supply
-- chain, and this port builds with @ghc --make@ against the boot
-- libraries alone — no cabal file, no aeson, no containers beyond what
-- ships.
--
-- AN IMMUTABLE VALUE, unlike `ocaml`'s. Haskell has no cheap mutable
-- map and does not need one here: where the other ports must refill an
-- options map IN PLACE so callbacks that closed over it see new values,
-- this port's callbacks read @instOptions@ through an 'IORef' on the
-- instance, so replacing the value is the same observation. The
-- mutability lives on the instance, where it belongs, rather than
-- inside every map.
--
-- A MAP PRESERVES INSERTION ORDER AND SORTS ON DEMAND. §4 rule 4 makes
-- order observable in several places (@keys@ is sorted, @pos@ is the
-- sorted-ref index), so both orders have to be available and the code
-- has to say which it means at each use.

module Value
  ( Value(..)
  , isNull, isBool, isNum, isStr, isList, isMap
  , vget, vhas, vset, vdel, vat, vpush, vlen, vitems
  , asStr, asNum, asBool
  , vkeys, sortedKeys
  , truthy, same
  , numStr, renderJson, parseJson
  ) where

import Data.Char (chr, digitToInt, isHexDigit, ord)
import Data.List (sort, foldl')
import Numeric (showHex)

data Value
  = VNull
  | VBool Bool
  | VNum Double
  | VStr String
  | VList [Value]
  -- | An association list, not a Data.Map: insertion order must
  -- survive, the maps here hold a handful of keys, and an ordered
  -- container keyed by String would sort them behind our back.
  | VMap [(String, Value)]
  deriving (Show)

isNull, isBool, isNum, isStr, isList, isMap :: Value -> Bool
isNull VNull = True
isNull _ = False
isBool (VBool _) = True
isBool _ = False
isNum (VNum _) = True
isNum _ = False
isStr (VStr _) = True
isStr _ = False
isList (VList _) = True
isList _ = False
isMap (VMap _) = True
isMap _ = False

-- | @vget@ answers 'VNull' for a missing key AND for a key holding JSON
-- null; @vhas@ distinguishes them, which is what §9.1's "an authored
-- null is not an absent key" needs.
vget :: Value -> String -> Value
vget (VMap kvs) k = maybe VNull id (lookup k kvs)
vget _ _ = VNull

vhas :: Value -> String -> Bool
vhas (VMap kvs) k = any ((== k) . fst) kvs
vhas _ _ = False

vset :: Value -> String -> Value -> Value
vset (VMap kvs) k v
  | any ((== k) . fst) kvs = VMap (map (\(a, b) -> if a == k then (a, v) else (a, b)) kvs)
  | otherwise = VMap (kvs ++ [(k, v)])
vset x _ _ = x

vdel :: Value -> String -> Value
vdel (VMap kvs) k = VMap (filter ((/= k) . fst) kvs)
vdel x _ = x

vat :: Value -> Int -> Value
vat (VList xs) i
  | i >= 0 && i < length xs = xs !! i
vat _ _ = VNull

vpush :: Value -> Value -> Value
vpush (VList xs) x = VList (xs ++ [x])
vpush v _ = v

vlen :: Value -> Int
vlen (VList xs) = length xs
vlen (VMap kvs) = length kvs
vlen _ = 0

vitems :: Value -> [Value]
vitems (VList xs) = xs
vitems _ = []

asStr :: Value -> String
asStr (VStr s) = s
asStr _ = ""

asNum :: Value -> Double
asNum (VNum n) = n
asNum _ = 0

asBool :: Value -> Bool
asBool (VBool b) = b
asBool _ = False

-- | Keys in INSERTION order.
vkeys :: Value -> [String]
vkeys (VMap kvs) = map fst kvs
vkeys _ = []

-- | Keys SORTED by byte order — §4 rule 4's deterministic walk.
-- Haskell's 'Ord' on 'String' compares by code point, which for the
-- ASCII the grammar admits is byte order.
sortedKeys :: Value -> [String]
sortedKeys = sort . vkeys

-- | §4 rule 4: truthiness is JSON's.
truthy :: Value -> Bool
truthy VNull = False
truthy (VBool b) = b
truthy (VNum n) = n /= 0
truthy (VStr s) = not (null s)
truthy _ = True

-- | Deep equality INCLUDING JSON type, which is the half that matters:
-- half the ports are written in languages whose @==@ says @true == 1@,
-- and @capability\/match@ exists to catch exactly that. Written out
-- rather than derived, because a derived 'Eq' would compare map order
-- as well and §4 rule 4 says key order never matters.
same :: Value -> Value -> Bool
same VNull VNull = True
same (VBool a) (VBool b) = a == b
same (VNum a) (VNum b) = a == b
same (VStr a) (VStr b) = a == b
same (VList a) (VList b) = length a == length b && and (zipWith same a b)
same (VMap a) (VMap b) =
  length a == length b
    && all (\(k, v) -> maybe False (same v) (lookup k b)) a
same _ _ = False

-- --- json -------------------------------------------------------------

-- | An integral double renders as an integer: the corpus's expected
-- values are written @1@, not @1.0@, and a port that emits the latter
-- fails every comparison for a reason that has nothing to do with the
-- behaviour under test.
numStr :: Double -> String
numStr n
  | not (isNaN n) && not (isInfinite n) && n == fromIntegral (round n :: Integer) =
      show (round n :: Integer)
  | otherwise = show n

escape :: String -> String
escape s = '"' : concatMap esc s ++ "\""
  where
    esc '"' = "\\\""
    esc '\\' = "\\\\"
    esc '\n' = "\\n"
    esc '\r' = "\\r"
    esc '\t' = "\\t"
    esc '\b' = "\\b"
    esc '\f' = "\\f"
    esc c
      | ord c < 0x20 =
          let h = showHex (ord c) ""
          in "\\u" ++ replicate (4 - length h) '0' ++ h
      | otherwise = [c]

-- | Canonical JSON, keys in SORTED order so two values that are 'same'
-- render identically — the corpus compares rendered forms in places.
renderJson :: Value -> String
renderJson VNull = "null"
renderJson (VBool True) = "true"
renderJson (VBool False) = "false"
renderJson (VNum n) = numStr n
renderJson (VStr s) = escape s
renderJson (VList xs) = "[" ++ intercalate' (map renderJson xs) ++ "]"
renderJson m@(VMap _) =
  "{" ++ intercalate' [escape k ++ ":" ++ renderJson (vget m k) | k <- sortedKeys m] ++ "}"

intercalate' :: [String] -> String
intercalate' [] = ""
intercalate' [x] = x
intercalate' (x : xs) = x ++ "," ++ intercalate' xs

-- | Parse, or 'Left' with a message.
parseJson :: String -> Either String Value
parseJson text = do
  (v, rest) <- pValue (skip text)
  case skip rest of
    [] -> Right v
    _ -> Left "trailing content"

skip :: String -> String
skip = dropWhile (`elem` " \t\n\r")

pValue :: String -> Either String (Value, String)
pValue s = case s of
  [] -> Left "unexpected end of input"
  ('n' : _) -> lit "null" VNull
  ('t' : _) -> lit "true" (VBool True)
  ('f' : _) -> lit "false" (VBool False)
  ('"' : _) -> do
    (str, rest) <- pString s
    Right (VStr str, rest)
  ('[' : rest) -> pArray (skip rest) []
  ('{' : rest) -> pObject (skip rest) []
  _ -> pNumber s
  where
    lit w v
      | take (length w) s == w = Right (v, drop (length w) s)
      | otherwise = Left "bad literal"

pArray :: String -> [Value] -> Either String (Value, String)
pArray (']' : rest) acc = Right (VList (reverse acc), rest)
pArray s acc = do
  (v, rest) <- pValue (skip s)
  case skip rest of
    (',' : more) -> pArray (skip more) (v : acc)
    (']' : more) -> Right (VList (reverse (v : acc)), more)
    _ -> Left "expected , or ] in array"

pObject :: String -> [(String, Value)] -> Either String (Value, String)
pObject ('}' : rest) acc = Right (VMap (reverse acc), rest)
pObject s acc = do
  (k, rest) <- pString (skip s)
  case skip rest of
    (':' : more) -> do
      (v, rest2) <- pValue (skip more)
      case skip rest2 of
        (',' : more2) -> pObject (skip more2) ((k, v) : acc)
        ('}' : more2) -> Right (VMap (reverse ((k, v) : acc)), more2)
        _ -> Left "expected , or } in object"
    _ -> Left "expected : in object"

pString :: String -> Either String (String, String)
pString ('"' : rest) = go rest ""
  where
    go [] _ = Left "unterminated string"
    go ('"' : more) acc = Right (reverse acc, more)
    go ('\\' : c : more) acc = case c of
      '"' -> go more ('"' : acc)
      '\\' -> go more ('\\' : acc)
      '/' -> go more ('/' : acc)
      'n' -> go more ('\n' : acc)
      'r' -> go more ('\r' : acc)
      't' -> go more ('\t' : acc)
      'b' -> go more ('\b' : acc)
      'f' -> go more ('\f' : acc)
      'u' -> do
        (hi, r1) <- hex4 more
        if hi >= 0xD800 && hi <= 0xDBFF
          then case r1 of
            ('\\' : 'u' : r2) -> do
              (lo, r3) <- hex4 r2
              go r3 (chr (0x10000 + ((hi - 0xD800) * 0x400) + (lo - 0xDC00)) : acc)
            _ -> go r1 (chr hi : acc)
          else go r1 (chr hi : acc)
      _ -> Left "bad escape"
    go ('\\' : []) _ = Left "unterminated escape"
    go (c : more) acc = go more (c : acc)
pString _ = Left "expected a string"

hex4 :: String -> Either String (Int, String)
hex4 s
  | length h == 4 && all isHexDigit h = Right (foldl' (\a c -> a * 16 + digitToInt c) 0 h, drop 4 s)
  | otherwise = Left "bad \\u escape"
  where
    h = take 4 s

pNumber :: String -> Either String (Value, String)
pNumber s
  | null tok = Left "unexpected character"
  | otherwise = case reads (fixup tok) :: [(Double, String)] of
      [(d, "")] -> Right (VNum d, rest)
      -- `reads`, not `read`: a bare `-` or a truncated `1e` reaches
      -- here from `Env`'s parse-or-string fallback (§9.5), and a reader
      -- that THROWS on a bad number rather than reporting one turns
      -- "this env value is a string" into a crash. The ocaml port had
      -- exactly this bug.
      _ -> Left "bad number"
  where
    (tok, rest) = span (`elem` "-+.eE0123456789") s
    -- Haskell's `reads` wants a digit before the point and after an
    -- exponent sign; JSON writes `1e5` and `-1`, both legal.
    fixup t =
      let t1 = case t of ('.' : _) -> '0' : t; ('-' : '.' : r) -> "-0." ++ r; _ -> t
          t2 = expand t1
      in t2
    expand t = case break (`elem` "eE") t of
      (m, []) -> m
      (m, _ : ex) -> (if '.' `elem` m then m else m ++ ".0") ++ "e" ++ dropWhile (== '+') ex
