-- | Ordering (§7) — one rule, one place.
--
-- sdkgen grew two special cases in @makeOptions@ (@test@, then
-- @station@) and the third was not far off. This sort is the whole
-- replacement, and the tiers are in this order for a reason:
--
-- >   1 constraints   before/after edges, by ref or by name
-- >   2 bands         integer, lower first, default 0
-- >   3 declaration   ties break by `pos`
--
-- CONSTRAINTS BEAT BANDS precisely so the correct tool wins when both
-- are present. A band expresses a genuine cross-cutting layer; a
-- constraint expresses a relationship between two specific things; and
-- a band chosen by trial and error to fix an ordering bug is a bug
-- wearing a number.

module Order (resolveOrder) where

import Data.List (sortBy)
import Ref
import Types
import Value

-- | A NUMBER, not a numeric string. @order.band@ accepting @"1"@ was a
-- surviving mutation in more than one port: the corpus pins the type
-- because two ports disagreeing about whether @"1"@ is a band is
-- exactly the divergence a shared corpus exists to remove.
bandOf :: Value -> Double
bandOf b = let x = vget (vget b "order") "band" in if isNum x then asNum x else 0

posOf :: Value -> Double
posOf b = let x = vget b "pos" in if isNum x then asNum x else 0

-- | Band first (lower runs first), then @pos@ — the position the
-- DOCUMENT visibly states, not the order instances happened to load and
-- not the incarnation @seq@.
rankKey :: Value -> (Double, Double)
rankKey b = (bandOf b, posOf b)

-- | Was a constraint actually declared? An ABSENT one and an EMPTY LIST
-- are both "no constraint"; only a non-empty spelling is an edge.
declared :: Value -> Bool
declared spec
  | isList spec = vlen spec > 0
  | isStr spec = not (null (asStr spec))
  | otherwise = False

-- | Matching is by REF, or by NAME across all of that definition's
-- instances (§7) — which is the whole reason the two spellings exist.
targets :: Value -> Value -> [String]
targets spec nodes = foldl add [] specs
  where
    specs = if isList spec then vitems spec else [spec]
    add acc oneval
      | not (isStr oneval) = acc
      | otherwise = foldl (hit (asStr oneval)) acc (vitems nodes)
    hit one acc node
      | r `elem` acc = acc
      | r == one || refName r == one = acc ++ [r]
      | otherwise = acc
      where
        r = asStr (vget node "ref")

-- | A PIN IS NOT A CONSTRAINT (§7).
--
-- Constraints and bands are negotiable by definition — they are what
-- plugins and documents say they want, and the sort's job is to satisfy
-- them all. A pin is the host stating a structural invariant of its own
-- architecture, which is a different kind of claim and must not lose a
-- tie to a document.
--
-- So a pin PLACES the binding at the named end, and an ordering that
-- would move it away is @plugin_order_pinned@ — rejected, not honoured
-- into a broken wrap.
applyPin :: [String] -> Value -> Value -> IO [String]
applyPin order edges pin
  | not (isMap pin) = return order
  | otherwise = do
      -- SORTED, not insertion order. A pin map is data — it can arrive
      -- from a host's own construction options in any order, and two
      -- names pinned to the same end are order-sensitive. Sorted is the
      -- one order every language agrees on, and @order\/pin#two-names@
      -- pins it.
      let placed = foldl place order (sortedKeys pin)
          index = zip placed [0 :: Int ..]
      -- Now check that the placement did not break a constraint. This
      -- is the half that makes a pin a rejection rather than an
      -- override: the host wins on position, but it does not get to
      -- silently discard a relationship a plugin declared.
      mapM_ (checkEdges index) (sortedKeys edges)
      return placed
  where
    place acc name =
      case filter ((== name) . refName) acc of
        (r : _) ->
          -- @first@/@outermost@ is index 0; @last@/@innermost@ is the
          -- end. §6.2 makes the first chain binding outermost, which is
          -- why the vocabulary is positional and why the two spellings
          -- pair this way.
          let want = asStr (vget pin name)
              rest = filter (/= r) acc
          in if want `elem` ["first", "outermost"] then r : rest else rest ++ [r]
        [] -> acc
    checkEdges index from =
      mapM_
        (\tov ->
           let t = asStr tov
           in case (lookup from index, lookup t index) of
                (Just a, Just b)
                  | a > b ->
                      raise "plugin_order_pinned"
                        ("a pin would move a binding an ordering constrains: "
                           ++ from ++ " must precede " ++ t)
                        (vset (vset (VMap []) "before" (VStr from)) "after" (VStr t))
                _ -> return ())
        (vitems (vget edges from))

resolveOrder :: Value -> Value -> IO Value
resolveOrder bindings pin = do
  let out = topo ready0 []
  if length out /= length nodes
    then
      let stuck = [r | b <- nodes, let r = asStr (vget b "ref"), r `notElem` out]
      in raise "plugin_order_cycle"
           ("before/after constraints cycle: " ++ joinArrow stuck)
           (details1 "cycle" (VList (map VStr stuck)))
    else do
      placed <- applyPin out edges pin
      return (VList (map VStr placed))
  where
    nodes = vitems bindings
    byref = foldl (\m b -> vset m (asStr (vget b "ref")) b) (VMap []) nodes

    -- Constraints are edges. A constraint naming an ABSENT binding is
    -- satisfied VACUOUSLY (§7) — a plugin ordered @after: 'test'@ must
    -- load in a host with no test plugin. That is sdkgen's __after__
    -- behaviour, kept.
    edges = foldl edgesFor (foldl (\m b -> vset m (asStr (vget b "ref")) (VList [])) (VMap []) nodes) nodes
    edgesFor acc b = withBefore
      where
        bref = asStr (vget b "ref")
        o = vget b "order"
        withAfter =
          if declared (vget o "after")
            then foldl (\m t -> vset m t (vpush (vget m t) (VStr bref))) acc (targets (vget o "after") bindings)
            else acc
        withBefore =
          if declared (vget o "before")
            then foldl (\m t -> vset m bref (vpush (vget m bref) (VStr t))) withAfter (targets (vget o "before") bindings)
            else withAfter

    indeg0 =
      foldl
        (\m from -> foldl (\m2 tov -> let t = asStr tov in vset m2 t (VNum (asNum (vget m2 t) + 1))) m (vitems (vget edges from)))
        (foldl (\m b -> vset m (asStr (vget b "ref")) (VNum 0)) (VMap []) nodes)
        (vkeys edges)

    ready0 = [b | b <- nodes, asNum (vget indeg0 (asStr (vget b "ref"))) == 0]

    -- Stable topological sort.
    topo ready acc = go ready indeg0 acc
      where
        go [] _ out = out
        go rs indeg out =
          let sorted = sortBy (\a b -> compare (rankKey a) (rankKey b)) rs
              next = head sorted
              nref = asStr (vget next "ref")
              tos = vitems (vget edges nref)
              (indeg', freed) = foldl release (indeg, []) tos
              release (m, fs) tov =
                let t = asStr tov
                    d = asNum (vget m t) - 1
                    m' = vset m t (VNum d)
                in (m', if d == 0 then fs ++ [vget byref t] else fs)
          in go (tail sorted ++ freed) indeg' (out ++ [nref])

joinArrow :: [String] -> String
joinArrow [] = ""
joinArrow [x] = x
joinArrow (x : xs) = x ++ " -> " ++ joinArrow xs
