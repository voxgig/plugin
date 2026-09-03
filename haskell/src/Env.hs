-- | Environment overrides (§9.5) — level 7 of the ladder.
--
-- One prefix, so nothing drifts: @VOXGIG_PLUGIN_*@.
--
-- >   VOXGIG_PLUGIN_PROFILE            the profile name
-- >   VOXGIG_PLUGIN_<REF>_<PATH>       one option
-- >   VOXGIG_PLUGIN_ACTIVE/INACTIVE    comma-separated refs, INACTIVE wins
--
-- THE ENCODING IS LOSSY, AND THIS SAYS SO RATHER THAN PRETENDING
-- OTHERWISE. Ref and path are upper-snake with @$@ -> @__@ and @.@ ->
-- @_@. But @_@ is legal in a name and in a tag, and the mapping folds
-- case, so @retry$fast@ and @retry__fast@ both encode to
-- @RETRY__FAST@.
--
-- Rather than restrict a grammar the rest of the stack already uses,
-- the host DETECTS THE COLLISION: it encodes every ref it holds, and a
-- key two refs claim is @plugin_env_ambiguous@, naming both.
--
-- Pure in the design sense — a function over a string map and a ref set
-- — but 'IO' because it raises.

module Env (encodeRef, applyEnv) where

import Data.Char (toLower, toUpper)
import Data.List (isPrefixOf, sortBy)
import Ref
import Types
import Value

envPrefix :: String
envPrefix = "VOXGIG_PLUGIN_"

encodeRef :: String -> String
encodeRef = concatMap enc
  where
    enc '$' = "__"
    enc '.' = "_"
    enc c = [toUpper c]

checkReserved :: String -> Value -> IO ()
checkReserved r reserved
  | isList reserved && vlen reserved > 0
  , any (\x -> isStr x && asStr x == refName r) (vitems reserved) =
      raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r)
        (details1 "ref" (VStr r))
  | otherwise = return ()

-- | Values parse as JSON, FALLING BACK TO STRING — so @8080@ is a
-- number, @true@ is a boolean, @{"a":1}@ is a map, and @hello@ is the
-- string it looks like rather than a parse error.
parseValue :: String -> Value
parseValue s = either (const (VStr s)) id (parseJson s)

splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest

trim :: String -> String
trim = f . f where f = reverse . dropWhile (`elem` " \t")

applyEnv :: Value -> IO Value
applyEnv input = do
  -- Encode every ref the host holds, and refuse a key that two of them
  -- claim. Done UP FRONT so the collision is reported even when no
  -- environment variable exercises it — a latent ambiguity is still an
  -- ambiguity, and finding it at deploy time is the failure this exists
  -- to prevent.
  canonRefs <- mapM canonRef (vitems refsIn)
  let byEncoded =
        foldl
          (\acc r -> let e = encodeRef r in vset acc e (vpush (let l = vget acc e in if isList l then l else VList []) (VStr r)))
          (VMap [])
          canonRefs
      encs = sortedKeys byEncoded

  mapM_ (collide byEncoded) encs

  -- LONGEST encoded ref first, so @retry$fast@ wins over @retry@ on
  -- @RETRY__FAST_MIN@. Shortest-first would read the tag as a path.
  let order = sortBy (\a b -> compare (length b, a) (length a, b)) encs

  foldl (step byEncoded order) (return start) (sortedKeys env)
  where
    env = let e = vget input "env" in if isMap e then e else VMap []
    refsIn = vget input "refs"
    reserved = vget input "reserved"
    start =
      vset (vset (vset (VMap []) "options" (VMap [])) "active" (VList [])) "inactive" (VList [])

    collide byEncoded e
      | vlen claims > 1 =
          raise "plugin_env_ambiguous"
            ("refs collide in the environment encoding as " ++ e ++ ": " ++ lo ++ ", " ++ hi)
            (vset (vset (VMap []) "encoded" (VStr e)) "refs" (VList [VStr lo, VStr hi]))
      | otherwise = return ()
      where
        claims = vget byEncoded e
        a = asStr (vat claims 0)
        b = asStr (vat claims 1)
        (lo, hi) = if a <= b then (a, b) else (b, a)

    step byEncoded order acc key
      | not (envPrefix `isPrefixOf` key) = acc
      | rest == "PROFILE" = do out <- acc; return (vset out "profile" (VStr value))
      | rest == "ACTIVE" || rest == "INACTIVE" = do
          out <- acc
          let slot = if rest == "ACTIVE" then "active" else "inactive"
          foldl
            (\a2 piece ->
               if null (trim piece)
                 then a2
                 else do
                   o <- a2
                   c <- canonRefS (trim piece)
                   -- The reservation covers EVERY input layer (§9.1).
                   -- VOXGIG_PLUGIN_INACTIVE=station is easier to set
                   -- than editing a config file, and INACTIVE has the
                   -- final word — so guarding documents alone would
                   -- leave the one lever this mechanism exists to deny
                   -- wide open.
                   checkReserved c reserved
                   return (vset o slot (vpush (vget o slot) (VStr c))))
            (return out)
            (splitOn ',' value)
      | otherwise = case matched of
          -- not for any ref this host holds
          Nothing -> acc
          Just enc -> do
            out <- acc
            let r = asStr (vat (vget byEncoded enc) 0)
            checkReserved r reserved
            -- A ref with no path sets nothing.
            if rest == enc
              then return out
              else do
                let pathText = drop (length enc + 1) rest
                    segs = map (map toLower) (splitOn '_' pathText)
                    opts = vget out "options"
                    node = let x = vget opts r in if isMap x then x else VMap []
                return (vset out "options" (vset opts r (setPath node segs (parseValue value))))
      where
        rest = drop (length envPrefix) key
        value = let raw = vget env key in if isStr raw then asStr raw else ""
        matched =
          case filter
                 (\cand ->
                    rest == cand
                      || (length rest > length cand
                            && cand `isPrefixOf` rest
                            && rest !! length cand == '_'))
                 order of
            (c : _) -> Just c
            [] -> Nothing

    setPath node [] _ = node
    setPath node [leaf] v = vset node leaf v
    setPath node (seg : more) v =
      let next = let x = vget node seg in if isMap x then x else VMap []
      in vset node seg (setPath next more v)
