-- | Dependency cardinality, policy, and the restart graph (§11.3).
--
-- TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
-- because only it knows what it can cope with:
--
-- >                | static (default)          | dynamic
-- >   -------------|---------------------------|--------------------------
-- >   mandatory    | unmet -> pending;         | unmet -> pending;
-- >   (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
-- >                |          recursively      |          notified
-- >   -------------|---------------------------|--------------------------
-- >   optional:true| never gates activation;   | never gates activation;
-- >                | a change deactivates and  | a change is a
-- >                | reactivates               | notification, nothing else
--
-- @dynamic@ means the plugin has said, IN WRITING, that it can survive
-- its provider being swapped underneath it. It is not the default
-- because most plugins cannot, and the cost of wrongly assuming they
-- can is a live instance holding a dead reference.

module Depend
  ( normRequire, requirements
  , restartsOnLoss, gatesActivation, restartCausing
  , dependencyCycle, checkCycle
  ) where

import Data.List (sort)
import Ref
import Types
import Value

-- | A bare string is shorthand for @{name}@.
normRequire :: Value -> Value
normRequire r
  | isStr r = vset (VMap []) "name" r
  | isMap r = r
  | otherwise = VMap []

-- | BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.
--
-- The instance-level @policy@ and @optional@ list are how a DOCUMENT
-- states the axis without editing the definition, and they apply to
-- every requirement. The per-requirement form is strictly more
-- expressive: an instance that is @static@ on its store and @dynamic@
-- on its metrics cannot be written at all at the instance level, and
-- that is the ordinary case rather than an exotic one.
--
-- @optional@ UNIONS rather than overriding — both spellings say this
-- requirement need not gate activation, and there is no reading under
-- which one of them means "actually, mandatory".
requirements :: Value -> Value
requirements options = VList (map one (vitems (vget options "requires")))
  where
    marked = vget options "optional"
    fallback = vget options "policy"
    one item = withPolicy
      where
        r = normRequire item
        base = foldl (\acc k -> vset acc k (vget r k)) (VMap []) (vkeys r)
        opt =
          truthy (vget r "optional")
            || (isList marked && any (`same` vget r "name") (vitems marked))
        withOpt = if opt then vset base "optional" (VBool True) else base
        withPolicy =
          if isNull (vget withOpt "policy") && not (isNull fallback)
            then vset withOpt "policy" fallback
            else withOpt

-- | Does losing this requirement's SELECTED provider restart the
-- consumer? The mandatory ones under @static@, and the @static@
-- optional ones — both make a capability change deactivate and
-- reactivate. @dynamic@ never restarts.
restartsOnLoss :: Value -> Bool
restartsOnLoss r = policy /= "dynamic"
  where
    p = vget r "policy"
    policy = if isStr p then asStr p else "static"

-- | Does an unmet requirement keep the consumer out of @live@?
--
-- CARDINALITY ALONE DECIDES THIS, NOT POLICY. @dynamic@ is a statement
-- about surviving a SWAP, not about starting without the thing at all —
-- a mandatory-dynamic consumer still waits in @pending@ for its first
-- provider. Conflating the two would let a plugin that declared it can
-- cope with replacement activate with nothing to call.
gatesActivation :: Value -> Bool
gatesActivation r = asBool (vget r "optional") /= True

-- | Edges that can cause a restart, which is exactly the set a cycle
-- must be detected over (§11.3): the mandatory requirements AND THE
-- @static@ OPTIONAL ONES, because both make a capability change
-- deactivate and reactivate the consumer — and a cycle of restarts does
-- not settle.
--
-- ONLY @dynamic@ OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
-- exclusion was for. An earlier draft of §11.3 excluded EVERY optional
-- edge and thereby admitted the non-terminating case it was trying to
-- permit.
restartCausing :: Value -> Bool
restartCausing r = gatesActivation r || restartsOnLoss r

-- | @[{ref, provides:[name], requires:[req]}]@ -> the cycle, or
-- 'Nothing'.
dependencyCycle :: Value -> Maybe [String]
dependencyCycle nodes = search (sortedKeys edges) (map (\r -> (r, White)) allRefs)
  where
    allRefs = [asStr (vget n "ref") | n <- vitems nodes]

    -- TWO INDEXES, NOT ONE MERGED MAP. Capability names and refs are
    -- matched differently — a capability by its exact name, a ref
    -- through the canonical spelling (§4 rule 5) — and one map keyed by
    -- both can only do one of them. Keyed by both and looked up raw, a
    -- cycle spelled @a$@/@b$@ finds no providers and EVADES the
    -- load-time check that exists to catch a non-terminating reconcile.
    byCap =
      foldl
        (\m n ->
           foldl (\m2 capv -> let c = asStr capv
                              in vset m2 c (vpush (let l = vget m2 c in if isList l then l else VList []) (VStr (asStr (vget n "ref")))))
             m (vitems (vget n "provides")))
        (VMap []) (vitems nodes)

    edges = foldl edgesFor (VMap []) (vitems nodes)
    edgesFor m n = vset m nref (VList (map VStr (sort outs)))
      where
        nref = asStr (vget n "ref")
        outs = foldl fromReq [] (vitems (vget n "requires"))
        fromReq acc r
          | not (restartCausing r) = acc
          | otherwise = foldl add acc from
          where
            rname = asStr (vget r "name")
            caps = map asStr (vitems (vget byCap rname))
            -- A node satisfies its own name AS A REF (§11.1),
            -- canonically — exactly what @providersof@ does at runtime,
            -- so the load-time graph and the running one agree about
            -- what an edge is.
            from = case tryRef rname of
              Just a | a `elem` allRefs && a `notElem` caps -> caps ++ [a]
              _ -> caps
            add a2 p = if p /= nref && p `notElem` a2 then a2 ++ [p] else a2

    -- Iterative DFS with an explicit stack: twenty ports, and several
    -- of them have no recursion budget worth relying on. Haskell could
    -- recurse freely; the shape is kept so the ports read alike.
    search [] _ = Nothing
    search (s : ss) colours
      | lookup s colours /= Just White = search ss colours
      | otherwise = case walk [(s, 0)] [s] (setC s Grey colours) of
          (Just c, _) -> Just c
          (Nothing, colours') -> search ss colours'

    setC k v = map (\(a, b) -> if a == k then (a, v) else (a, b))
    getC k cs = maybe White id (lookup k cs)

    walk [] _ colours = (Nothing, colours)
    walk ((tref, i) : stack) path colours
      | i >= length tos = walk stack (init path) (setC tref Black colours)
      | c == Grey =
          -- Report the cycle itself, not the walk that found it.
          (Just (dropWhile (/= nxt) path ++ [nxt]), colours)
      | c == Black = walk ((tref, i + 1) : stack) path colours
      | otherwise = walk ((nxt, 0) : (tref, i + 1) : stack) (path ++ [nxt]) (setC nxt Grey colours)
      where
        tos = vitems (vget edges tref)
        nxt = asStr (tos !! i)
        c = getC nxt colours

data Colour = White | Grey | Black deriving (Eq)

-- | Raise on a cycle, naming it. Separate from the detector so the
-- detector stays pure and corpus-testable.
checkCycle :: Value -> IO ()
checkCycle nodes = case dependencyCycle nodes of
  Nothing -> return ()
  Just cyc ->
    raise "plugin_dependency_cycle" ("requirements cycle: " ++ arrows cyc)
      (details1 "cycle" (VList (map VStr cyc)))
  where
    arrows [] = ""
    arrows [x] = x
    arrows (x : xs) = x ++ " -> " ++ arrows xs
