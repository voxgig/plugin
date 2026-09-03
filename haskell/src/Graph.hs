-- | Whole-graph resolution (§11.4) — a phase, not a discovery.
--
-- "Activate, and wait in @pending@ if you must" is correct and, on its
-- own, produces a terrible experience: apply twenty instances against a
-- registry missing one thing and you get NINETEEN pending rows and no
-- statement of what is actually wrong.
--
-- 'resolveGraph' is a PURE FUNCTION of the registry and the intended
-- activation set. No callbacks run, no state changes, nothing is
-- touched. It answers for the whole graph at once which instances can
-- be live, and for each blocked one THE SPECIFIC REQUIREMENT that is
-- unmet, and why.
--
-- The failure mode being designed against is a famous one: OSGi's
-- resolver is correct and its diagnostics are legendarily unusable. A
-- resolver that says "blocked" without saying WHY has moved the problem
-- rather than solved it, so @why@ is part of the contract.

module Graph (resolveGraph) where

import Capability
import Data.List (sort)
import Ref
import Value
import Version

candidates :: Value -> Value -> Value
candidates byref name = VList (concatMap forRef (sortedKeys byref))
  where
    -- A NODE SATISFIES ITS OWN REF (§11.1), and this is where the graph
    -- learned it. Considering only declared capabilities made
    -- @resolve@ answer @absent@ about a provider sitting right there
    -- and live — §11.4's whole job is explaining the graph the runtime
    -- reconciles, and it was explaining a different one. Canonical (§4
    -- rule 5), and tolerant, because a capability name need not be a
    -- well-formed ref.
    asref = if isStr name then tryRef (asStr name) else Nothing
    forRef r
      -- The ref match WINS OUTRIGHT for that node, as at runtime: one
      -- candidate, not two, for a node both named @b@ and providing
      -- @b@ — without the skip the blocked-chain explanation named it
      -- twice.
      | asref == Just r = [cand (vset (VMap []) "name" name)]
      | otherwise = [cand p | p <- vitems (vget node "provides"), same (vget p "name") name]
      where
        node = vget byref r
        pos = let x = vget node "pos" in if isNum x then x else VNum 0
        cand prov =
          vset (vset (vset (VMap []) "ref" (vget node "ref")) "pos" pos) "provides" prov

blockedOf :: Value -> Value -> Value -> Value
blockedOf node unmet why =
  vset (vset (vset (VMap []) "ref" (vget node "ref")) "unmet" unmet) "why" why

why1 :: String -> Value
why1 kind = vset (VMap []) "kind" (VStr kind)

sortedStrings :: [String] -> Value
sortedStrings = VList . map VStr . sort

-- | The FIRST unmet requirement, with the most specific explanation
-- available. Order matters: "no provider at all" and "a provider at the
-- wrong version" are different problems and a reader must not have to
-- guess which they have.
firstUnmet :: Value -> Value -> Value -> IO (Maybe Value)
firstUnmet node byref resolved = go (vitems (vget node "requires"))
  where
    go [] = return Nothing
    go (req : rest)
      | truthy (vget req "optional") = go rest
      | vlen allc == 0 = return (Just (blockedOf node name (why1 "absent")))
      | otherwise = do
          ok <- resolveCapability req allc
          if vlen ok > 0
            then
              -- A provider exists and matches — but if none of them is
              -- itself resolved, this node is blocked BEHIND it, and
              -- the chain is the useful answer rather than "unmet".
              if any (\c -> vhas resolved (asStr (vget c "ref"))) (vitems ok)
                then go rest
                else
                  let w = vset (why1 "blocked") "chain"
                            (sortedStrings [asStr (vget c "ref") | c <- vitems ok])
                  in return (Just (blockedOf node name w))
            else do
              -- Providers exist and none matched. Say which test
              -- failed.
              byVersion <- versionWhy
              case byVersion of
                Just b -> return (Just b)
                Nothing -> return (Just (maybe (blockedOf node name (why1 "absent")) id matchWhy))
      where
        name = vget req "name"
        allc = candidates byref name
        range = vget req "range"
        m = vget req "match"

        versionWhy
          | isNull range = return Nothing
          | otherwise = do
              found <- concat <$> mapM check (vitems allc)
              return $
                if null found
                  then Nothing
                  else
                    Just
                      (blockedOf node name
                         (vset (vset (why1 "version") "range" range) "found" (sortedStrings found)))
          where
            check c = do
              let version = vget (vget c "provides") "version"
              if isNull version
                then return ["(none)"]
                else do
                  okv <- satisfiesQ version range
                  return [asStr version | not okv]

        matchWhy
          | isNull m = Nothing
          | otherwise = firstJust [failing c | c <- vitems allc]
          where
            failing c = firstJust [bad c k | k <- sortedKeys m]
            bad c k
              -- The same recursive partial match the selection applies,
              -- so a nested requirement that FAILED the selection is
              -- also the one the diagnosis names (§11.4).
              | not (vhas attrs k) || not (capMatchValue (vget m k) (vget attrs k)) =
                  Just
                    (blockedOf node name
                       (vset (vset (vset (why1 "match") "failing" (VStr k))
                                "want" (vget m k))
                          "found" (vget attrs k)))
              | otherwise = Nothing
              where
                attrs = let a = vget (vget c "provides") "attrs" in if isNull a then VMap [] else a
            firstJust xs = case [x | Just x <- xs] of (x : _) -> Just x; [] -> Nothing

resolveGraph :: Value -> IO Value
resolveGraph nodes = do
  resolved <- fixpoint (VMap [])
  blocked <- foldMapBlocked resolved
  return
    ( vset (vset (VMap []) "resolved" (VList (map VStr (sortedKeys resolved))))
        "blocked" (VList (map (vget blocked) (sortedKeys blocked))) )
  where
    byref = foldl (\m n -> vset m (asStr (vget n "ref")) n) (VMap []) (vitems nodes)

    -- Fixed point: a node resolves when every mandatory requirement is
    -- met by an ALREADY-RESOLVED provider. Iterating to a fixed point
    -- is what makes a provider that is itself blocked propagate, rather
    -- than each node being judged against the raw registry.
    fixpoint resolved = do
      (next, moved) <- foldl step (return (resolved, False)) (vitems nodes)
      if moved then fixpoint next else return next
      where
        step acc n = do
          (cur, moved) <- acc
          let r = asStr (vget n "ref")
          if vhas cur r
            then return (cur, moved)
            else do
              u <- firstUnmet n byref cur
              case u of
                Nothing -> return (vset cur r (VBool True), True)
                Just _ -> return (cur, moved)

    foldMapBlocked resolved = foldl step (return (VMap [])) (vitems nodes)
      where
        step acc n = do
          cur <- acc
          let r = asStr (vget n "ref")
          if vhas resolved r
            then return cur
            else do
              u <- firstUnmet n byref resolved
              return (maybe cur (vset cur r) u)
