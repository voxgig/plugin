-- | The declarative document (§9): normalization, and the ten-level
-- precedence ladder.
--
-- TWO FUNCTIONS, AND THE SPLIT BETWEEN THEM IS FORCED.
--
-- 'normalizeConfig' normalizes STRUCTURE and ENTRY KEYS. It does not
-- merge options, and cannot: §9.4 makes merge behaviour a property of
-- the definition's option SHAPE, which normalization has never seen. A
-- normalizer that flattened the option layers would make
-- @$MERGE: append@ unimplementable at load time, because the layers it
-- must concatenate would already be collapsed.
--
-- 'resolveOptions' applies the ladder, and it is the only place that
-- knows the shape.

module Config (normalizeConfig, resolveOptions, checkShape) where

import Data.List (sort)
import Ref
import Types
import Value

-- | §9.1: reservation is all-or-nothing per NAME, so the tagged forms
-- go too. A configuration surface that can disable the thing reading it
-- is not a surface, it is a trap.
checkReserved :: String -> Value -> IO ()
checkReserved r reserved
  | isList reserved && vlen reserved > 0
  , any (\x -> isStr x && asStr x == refName r) (vitems reserved) =
      raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r)
        (details1 "ref" (VStr r))
  | otherwise = return ()

-- | Both document forms reduce to @{ref -> entry}@ plus the order the
-- form implies: array POSITION for the array form, sorted refs for the
-- map form.
entriesOf :: Value -> IO (Value, [String])
entriesOf src
  | isNull src = return (VMap [], [])
  | isList src = do
      pairs <- mapM (\item -> do r <- canonRef (vget item "ref"); return (r, item)) (vitems src)
      return (foldl (\m (r, item) -> vset m r item) (VMap []) pairs, map fst pairs)
  | otherwise = do
      -- Map-form refs arrive as KEYS, through a different path than an
      -- array element's @ref@ field — and must canonicalize the same
      -- way.
      pairs <- mapM (\k -> do r <- canonRefS k; return (r, vget src k)) (vkeys src)
      let m = foldl (\acc (r, e) -> vset acc r e) (VMap []) pairs
      -- Byte-wise, NOT locale-aware and NOT case-folded. All-lowercase
      -- refs sort identically under all three, so only mixed input
      -- discriminates: '@' is 0x40, uppercase 0x41-0x5A, lowercase
      -- 0x61-0x7A.
      return (m, sort (vkeys m))

pick :: Value -> String -> Value -> Value
pick src key dflt
  | isMap src && vhas src key && not (isNull (vget src key)) = vget src key
  | otherwise = dflt

normalizeConfig :: Value -> IO Value
normalizeConfig input = do
  (baseMap, baseOrder) <- entriesOf baseInst
  (overMap, overOrder) <- entriesOf overInst

  mapM_ (\m -> mapM_ (`checkReserved` reserved) (vkeys m)) [baseMap, overMap, baseDef, overDef]

  -- A PARTIAL ARRAY IS NOT A FILTER (§9.1). sdkgen learned this the
  -- hard way: deriving order from a partial array silently dropped
  -- config-activated features. Refs in the base but absent from the
  -- overlay still load, in sorted position AFTER the listed ones. A
  -- profile may also INTRODUCE a ref the base never declared.
  --
  -- The remainder keeps the BASE's own order — array position for the
  -- array form, sorted refs for the map form. Re-sorting here would
  -- discard an array document's positional order entirely, which is the
  -- one thing the array form exists to express.
  let order = foldl (\acc r -> if r `elem` acc then acc else acc ++ [r]) [] (overOrder ++ baseOrder)
      instances = foldl (entry baseMap overMap) (VMap []) (zip [0 ..] order)

  -- @default@ DECLARES NOTHING (§9.3). It is a base for every instance
  -- of that definition; it does not create one, and an entry for a name
  -- with no instances is inert rather than an error — which is what
  -- makes a shared library of defaults shippable.
  let defOut =
        foldl (\m k -> vset m k (vget overDef k))
          (foldl (\m k -> vset m k (vget baseDef k)) (VMap []) (vkeys baseDef))
          (vkeys overDef)

  return
    ( vset (vset (vset (VMap []) "instance" instances) "order" (VList (map VStr order)))
        "default" defOut )
  where
    doc = let d = vget input "doc" in if isMap d then d else VMap []
    keySpec = vget input "keys"
    keyOr k d = let v = vget keySpec k in if isStr v then asStr v else d
    ikey = keyOr "instance" "instance"
    dkey = keyOr "default" "default"
    reserved = vget input "reserved"
    profile = vget input "profile"

    -- The rename is applied at TWO PLACES AND NO OTHERS: the document
    -- root, and every profile.<name> overlay root (§9.1). A rename
    -- applied only at the root would leave @profile.prod.sdk@
    -- untranslated and silently drop every environment override the
    -- host depends on. Recursing further would be worse: option data is
    -- the definition's.
    baseInst = vget doc ikey
    baseDef = let d = vget doc dkey in if isMap d then d else VMap []
    overlay = if isStr profile then vget (vget doc "profile") (asStr profile) else VNull
    overInst = if isMap overlay then vget overlay ikey else VNull
    overDef = let d = if isMap overlay then vget overlay dkey else VNull
              in if isMap d then d else VMap []

    entry baseMap overMap acc (i, r) = vset acc r ent
      where
        b = vget baseMap r
        o = vget overMap r
        -- MERGE THE ENTRIES AS AUTHORED, THEN APPLY DEFAULTS TO THE
        -- RESULT (§9.3). A safety rule, not a tidiness one: if the
        -- overlay had its defaults filled in before merging it would
        -- carry a synthesized active:true and overwrite a base's false
        -- — silently re-enabling a deliberately disabled integration in
        -- production.
        active = pick o "active" (pick b "active" (VBool True))
        start = pick o "start" (pick b "start" (VStr "eager"))
        ord = pick o "order" (pick b "order" VNull)
        -- Option layers, levels 3-6, IN LADDER ORDER. Never merged here.
        nm = refName r
        layerOf src = [vget src "options" | isMap src && vhas src "options"]
        layers = concatMap layerOf [vget baseDef nm, b, vget overDef nm, o]
        base' =
          vset (vset (vset (vset (VMap []) "pos" (VNum (fromIntegral (i :: Int))))
                        "active" active) "start" start)
            "optionlayers" (VList layers)
        ent = if isNull ord then base' else vset base' "order" ord

-- --------------------------------------------------------------------
-- resolveOptions — §9.3's ten levels, and §9.4's merge directives
-- --------------------------------------------------------------------

-- | §9.4: N is an integer of at least 1, and everything else is an
-- error.
--
-- @{"deep": 0}@ is rejected DESPITE having an obvious reading, because
-- "replace at this key" already has a spelling and two spellings for
-- one behaviour is the defect class this repo exists to avoid. Without
-- the stated domain each port picks its own reading — reject, replace,
-- unlimited merge, or clamp to 1 — and the same document resolves
-- differently per language.
checkShape :: Value -> IO ()
checkShape shape
  | not (isMap shape) = return ()
  | otherwise = mapM_ one (vkeys shape)
  where
    one k
      | not (isMap v) || not (vhas v "$MERGE") = return ()
      | isStr d = if asStr d `elem` ["replace", "append"]
                    then return ()
                    else bad ("invalid $MERGE directive at " ++ k ++ ": " ++ asStr d)
      | isMap d && vhas d "deep" =
          let nv = vget d "deep"
              x = asNum nv
          in if not (isNum nv) || x /= fromIntegral (round x :: Integer) || x < 1
               then bad ("invalid $MERGE deep at " ++ k ++ ": " ++ renderJson nv)
               else return ()
      | otherwise = bad ("invalid $MERGE directive at " ++ k ++ ": " ++ renderJson d)
      where
        v = vget shape k
        d = vget v "$MERGE"
        bad t = raise "plugin_shape_invalid" t (details2 "key" (VStr k) "directive" d)

-- | The shape's non-directive values are the level-1 defaults.
defaultsOf :: Value -> Value
defaultsOf shape
  | not (isMap shape) = VMap []
  | otherwise = foldl keep (VMap []) (vkeys shape)
  where
    keep acc k =
      let v = vget shape k
      in if isMap v && vhas v "$MERGE" then acc else vset acc k v

optsOf :: Value -> String -> IO (Maybe Value)
optsOf src key
  | isNull src = return Nothing
  -- The array form is equivalent to the map form (§9.1).
  | isList src = firstJust (map fromItem (vitems src))
  | otherwise = firstJust (map fromKey (vkeys src))
  where
    fromItem item = do
      r <- canonRef (vget item "ref")
      return (if r == key && vhas item "options" then Just (vget item "options") else Nothing)
    fromKey k = do
      r <- canonRefS k
      let e = vget src k
      return (if r == key && vhas e "options" then Just (vget e "options") else Nothing)
    firstJust [] = return Nothing
    firstJust (a : as) = do
      x <- a
      case x of Just _ -> return x; Nothing -> firstJust as

-- | Merge N levels below this key, replace below that.
deepTo :: Value -> Value -> Integer -> Value
deepTo base over n
  | n <= 0 = over
  | not (isMap base && isMap over) = over
  | otherwise =
      foldl (\acc k -> vset acc k (deepTo (vget acc k) (vget over k) (n - 1)))
        (foldl (\acc k -> vset acc k (vget base k)) (VMap []) (vkeys base))
        (vkeys over)

-- | Merge ONE layer onto the accumulator, honouring the shape's
-- directives. The directive holds at EVERY precedence level, not only
-- between document levels — §9.4 makes it a property of the shape,
-- which does not know which layer a value arrived from.
mergeOne :: Value -> Value -> Value -> Value
mergeOne base over shape
  | isNull over = base
  | not (isMap base && isMap over) = over
  | otherwise = foldl step seeded (vkeys over)
  where
    seeded = foldl (\acc k -> vset acc k (vget base k)) (VMap []) (vkeys base)
    step acc k
      | isStr directive && asStr directive == "replace" = vset acc k o
      | isStr directive && asStr directive == "append" =
          vset acc k (VList ((if isList b then vitems b else []) ++ (if isList o then vitems o else [o])))
      | isMap directive && vhas directive "deep" =
          vset acc k (deepTo b o (round (asNum (vget directive "deep"))))
      -- Library default: deep for maps, REPLACE for lists.
      -- struct.merge is element-wise by index, which for option maps is
      -- nearly always wrong — ["a"] over ["x","y","z"] yielding
      -- ["a","y","z"] is the defect station hit on secrets.providers.
      | isMap b && isMap o = vset acc k (mergeOne b o VNull)
      | otherwise = vset acc k o
      where
        entry = if isMap shape then vget shape k else VNull
        directive = if isMap entry then vget entry "$MERGE" else VNull
        b = vget acc k
        o = vget over k

resolveOptions :: Value -> IO Value
resolveOptions input = do
  checkShape shape
  r <- canonRef (vget input "ref")
  let name = refName r
      overlay = if isStr profile then vget (vget doc "profile") (asStr profile) else VNull
      over key = if isMap overlay then vget overlay key else VNull
      some v = if isNull v then Nothing else Just v
  l3 <- optsOf (vget doc "default") name
  l4 <- optsOf (vget doc "instance") r
  l5 <- optsOf (over "default") name
  l6 <- optsOf (over "instance") r
  -- ONE ordered merge, lowest to highest. Levels 3-6 are not two
  -- namespaces collapsed separately and composed afterwards: that
  -- inverts the rule that PROFILE SPECIFICITY OUTRANKS DEFINITION
  -- SPECIFICITY, so a prod per-definition default would lose to a base
  -- instance value.
  let layers =
        [ Just (defaultsOf shape)              -- 1
        , some (vget input "hostdefaults")     -- 2
        , l3, l4, l5, l6                       -- 3-6
        , some (vget input "env")              -- 7
        , some (vget input "hostoptions")      -- 8
        , some (vget input "loadoptions")      -- 9
        , some (vget input "patch")            -- 10
        ]
  return (foldl (\acc l -> maybe acc (\x -> mergeOne acc x shape) l) (VMap []) layers)
  where
    shape = let s = vget input "shape" in if isMap s then s else VMap []
    doc = let d = vget input "doc" in if isMap d then d else VMap []
    profile = vget input "profile"
