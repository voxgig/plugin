-- | The host: the lifecycle state machine (§5), extension points (§6),
-- and resource capture (§8).
--
-- TWO RULES SHAPE EVERY FUNCTION HERE.
--
-- Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
-- never interleaved; a transition triggered from inside a lifecycle
-- callback is @plugin_reentrant@. A hard rule, because it is the only
-- way the semantics can be identical in Go, in Ruby and in
-- single-threaded JavaScript — and in Haskell, which has no event loop
-- to hide behind.
--
-- Reconciliation is EAGER (§18's portability budget). A transition
-- settles by running the state machine to a fixed point, not by
-- suspending on a promise.

module Host where

import Capability (resolveCapability)
import Catalog
import Config (normalizeConfig, resolveOptions)
import Control.Exception (SomeException, catch, finally, throwIO, try)
import Control.Monad (foldM, forM, forM_, unless, when)
import Data.IORef
import Data.List (sort, sortBy)
import Data.Maybe (catMaybes, fromMaybe, isNothing)
import Defs
import Depend
import Export (resolveExport)
import Order (resolveOrder)
import Point
import Ref
import Types
import Value

-- ---------------------------------------------------------------------
-- construction and registry helpers
-- ---------------------------------------------------------------------

makeHost :: HostOptions -> IO Host
makeHost o = do
  cat <- maybe makeCatalog return (oCatalog o)
  coordinated <- newIORef False
  instances <- newIORef []
  lg <- newIORef (VList [])
  events <- newIORef (VList [])
  seqn <- newIORef 0
  open <- newIORef 0
  intr <- newIORef False
  phase <- newIORef ""
  return
    Host
      { hCatalog = cat
      , hReserved = oReserved o
      , hKeys = oKeys o
      , hDefaults = oDefaults o
      , hProfile = oProfile o
      , hPoints = if isMap (oPoints o) then oPoints o else VMap []
      , hBases = oBases o
      , hDependency = if null (oDependency o) then "restart" else oDependency o
      , hCoordinated = coordinated
      , hInstances = instances
      , hLog = lg
      , hEvents = events
      , hSeqn = seqn
      , hOpen = open
      , hInTransition = intr
      , hPhase = phase
      }

hostDefine :: Host -> Definition -> IO ()
hostDefine h = catalogAdd (hCatalog h)

findInst :: Host -> String -> IO (Maybe Inst)
findInst h r = do
  xs <- readIORef (hInstances h)
  return (case filter ((== r) . iRef) xs of (x : _) -> Just x; [] -> Nothing)

-- | Every instance ref, SORTED — the deterministic walk §4 rule 4
-- requires in a language whose containers have no inherent order.
sortedRefs :: Host -> IO [String]
sortedRefs h = (sort . map iRef) <$> readIORef (hInstances h)

-- ---------------------------------------------------------------------
-- observation
-- ---------------------------------------------------------------------

hostList :: Host -> IO Value
hostList h = do
  rs <- sortedRefs h
  foldM add (VMap []) rs
  where
    add acc r = do
      me <- findInst h r
      case me of
        Nothing -> return acc
        Just e -> do s <- readIORef (iStatus e); return (vset acc r (VStr s))

-- | The VALIDATING canonicalizer, not the forgiving one: a lookup with
-- a malformed ref is @plugin_bad_name@, not a miss
-- (@declare\/lookup#malformed@). Rust and swift both wrote this with
-- @canon@ and failed that entry.
hostInstance :: Host -> String -> IO (Maybe Inst)
hostInstance h r = canonRefS r >>= findInst h

observable :: Host -> Maybe Value -> IO Value
observable h result = do
  st <- hostList h
  op <- readIORef (hOpen h)
  lg <- readIORef (hLog h)
  return
    ( vset (vset (vset (vset (VMap []) "status" st) "open" (VNum op)) "log" lg)
        "result" (fromMaybe VNull result) )

hostTrace :: Host -> IO Value
hostTrace = readIORef . hEvents

instName :: Inst -> String
instName = refName . iRef

instTag :: Inst -> String
instTag e = case break (== '$') (iRef e) of
  (_, '$' : t) -> t
  _ -> ""

-- ---------------------------------------------------------------------
-- guards
-- ---------------------------------------------------------------------

guardHost :: Host -> IO ()
guardHost h = do
  t <- readIORef (hInTransition h)
  when t $
    raise "plugin_reentrant" "transition attempted from inside a lifecycle callback" (VMap [])

need :: Host -> String -> IO Inst
need h r0 = do
  r <- canonRefS r0
  me <- findInst h r
  case me of
    Just e -> return e
    Nothing -> raise "plugin_not_loaded" ("no such instance: " ++ r) (details1 "ref" (VStr r))

checkReservedH :: Host -> String -> IO ()
checkReservedH h r =
  when (isList res && vlen res > 0
          && any (\x -> isStr x && asStr x == refName r) (vitems res)) $
    raise "plugin_ref_reserved" ("ref is reserved by the host: " ++ r) (details1 "ref" (VStr r))
  where
    res = hReserved h

-- ---------------------------------------------------------------------
-- scope
-- ---------------------------------------------------------------------

-- | A selection belongs to ONE activation (§11.4). Leaving @live@ by
-- any door drops it, so the next activation ranks afresh — keeping it
-- would make a consumer prefer a provider it never actually ran
-- against.
--
-- Answers the errors the scope raised. §8.3: "A failing release does
-- not stop the rest. Every entry runs, in reverse order, whatever any
-- of them does; the errors are collected and raised as one
-- @plugin_release_failed@."
unwind :: Host -> Inst -> IO Value
unwind h e = do
  writeIORef (iSelected e) (VMap [])
  entries <- readIORef (iScope e)
  errs <- foldM one [] (reverse entries)
  writeIORef (iScope e) []
  return (VList (reverse errs))
  where
    one acc s = do
      d <- readIORef (seDone s)
      if d
        then return acc
        else do
          writeIORef (seDone s) True
          when (seCounts s) $ modifyIORef' (hOpen h) (subtract 1)
          case seFn s of
            Nothing -> return acc
            Just f ->
              (f >> return acc) `catch` \err -> return (VStr (peMessage err) : acc)

-- | §8.3: "A failed release ends the instance in @failed@, exactly as a
-- failed callback does (§5.2) — a release that raised may have leaked,
-- and an instance that may be holding resources it cannot account for
-- must not be reactivated."
releaseCheck :: Inst -> Value -> IO ()
releaseCheck e errors =
  when (vlen errors > 0) $ do
    writeIORef (iStatus e) "failed"
    raise "plugin_release_failed"
      ("release failed for " ++ iRef e ++ ": " ++ semis (map asStr (vitems errors)))
      (vset (vset (VMap []) "ref" (VStr (iRef e))) "cause" errors)
  where
    semis [] = ""
    semis [x] = x
    semis (x : xs) = x ++ "; " ++ semis xs

-- ---------------------------------------------------------------------
-- the instance api
-- ---------------------------------------------------------------------

instAcquire :: Inst -> IO ScopeEntry
instAcquire e = do
  -- §8.1: resources are "acquired during @activate@ — the scope's
  -- actual job".
  p <- readIORef (hPhase (iOwner e))
  unless (p == "activate") $
    raise "plugin_release_scope" "acquire called outside activate" (VMap [])
  d <- newIORef False
  let s = ScopeEntry Nothing d True
  modifyIORef' (iScope e) (++ [s])
  modifyIORef' (hOpen (iOwner e)) (+ 1)
  return s

-- | Hand a resource back before teardown. Idempotent, and the scope
-- keeps the entry: unwinding it again must be a no-op, or releasing
-- early would make teardown wrong.
instGiveback :: Inst -> ScopeEntry -> IO ()
instGiveback e s = do
  d <- readIORef (seDone s)
  unless d $ do
    writeIORef (seDone s) True
    when (seCounts s) $ modifyIORef' (hOpen (iOwner e)) (subtract 1)

instRelease :: Inst -> Maybe Release -> IO ()
instRelease e fn = do
  -- §8.3: "@inst.release@ outside @activate@ is
  -- @plugin_release_scope@". Being in a transition is true in @define@
  -- too, and a scope entry registered there is never unwound —
  -- @unload@ on a merely @loaded@ instance does not unwind, because a
  -- loaded instance is not supposed to hold anything.
  p <- readIORef (hPhase (iOwner e))
  unless (p == "activate") $
    raise "plugin_release_scope" "release called outside activate" (VMap [])
  -- SYMMETRIC WITH @acquire@, and it has to be: @open@ counts the
  -- resources CURRENTLY HELD, so an entry that is registered and then
  -- unwound must leave the count where it found it. Incrementing on
  -- registration and never decrementing made every @release@ a
  -- permanent leak in the counter.
  d <- newIORef False
  modifyIORef' (iScope e) (++ [ScopeEntry fn d True])
  modifyIORef' (hOpen (iOwner e)) (+ 1)

instBind :: Inst -> String -> Maybe Hook -> Maybe ChainFn -> Value -> IO ()
instBind e point hook chain band = do
  -- §12's @plugin_bind_scope@: "binding declared outside @define@".
  -- §8.1 puts binding declaration in @define@ and insertion at a
  -- SUCCESSFUL activate, and the guard was the half that never got
  -- written — so a binding added from @activate@ went live without
  -- being part of the loaded definition, and a deactivate/activate
  -- cycle appended it again. The code was in the table before anything
  -- raised it.
  p <- readIORef (hPhase h)
  unless (p == "define") $
    raise "plugin_bind_scope" ("bind called outside define: " ++ point)
      (vset (vset (VMap []) "ref" (VStr (iRef e))) "point" (VStr point))
  unless (vhas (hPoints h) point) $
    raise "plugin_point_unknown" ("no such point: " ++ point) (details1 "point" (VStr point))
  modifyIORef' (iBindings e)
    (++ [Bound (iRef e) point (if isNum band then asNum band else 0) hook chain])
  where
    h = iOwner e

instBindHook :: Inst -> String -> Hook -> Value -> IO ()
instBindHook e p f = instBind e p (Just f) Nothing

instBindChain :: Inst -> String -> ChainFn -> Value -> IO ()
instBindChain e p f = instBind e p Nothing (Just f)

instExport :: Inst -> String -> Value -> IO ()
instExport e k v = modifyIORef' (iExports e) (\m -> vset m k v)

instProvides :: Inst -> Value -> IO ()
instProvides e p = modifyIORef' (iProvides e) (`vpush` p)

instPosition :: Inst -> String -> IO Value
instPosition e = positionOf (iOwner e) (iRef e)

-- ---------------------------------------------------------------------
-- running a callback
-- ---------------------------------------------------------------------

runCb :: Host -> Inst -> String -> IO ()
runCb h e at = do
  modifyIORef' (hLog h) (`vpush` VStr (iRef e ++ ":" ++ at))
  st <- readIORef (iStatus e)
  let ev =
        vset (vset (vset (vset (VMap []) "ref" (VStr (iRef e))) "event" (VStr at))
                "seq" (VNum (iSeq e)))
          "status" (VStr st)
  modifyIORef' (hEvents h) (`vpush` ev)

  case callbackFor (iDef e) at of
    Nothing -> return ()
    Just f -> do
      writeIORef (hInTransition h) True
      writeIORef (hPhase h) at
      r <- try (f e)
      writeIORef (hInTransition h) False
      writeIORef (hPhase h) ""
      case r of
        Right () -> return ()
        Left err ->
          -- §12: @plugin_define_failed@ and its three siblings are "a
          -- callback raised; wraps the cause". AN ERROR THAT ALREADY
          -- CARRIES A CODE KEEPS IT — the code is the error's identity,
          -- and a plugin that raised @store_unreachable@ must not have
          -- it rewritten. Only a code-less error is wrapped, which is
          -- the ordinary case for a callback that let a library error
          -- escape.
          if not (null (peCode err)) && peCode err /= "plugin_bare"
            then throwIO err
            else
              raise ("plugin_" ++ at ++ "_failed")
                (iRef e ++ " raised in " ++ at ++ ": " ++ peText err)
                (vset (vset (VMap []) "ref" (VStr (iRef e))) "cause" (VStr (peText err)))

-- ---------------------------------------------------------------------
-- requirements and providers
-- ---------------------------------------------------------------------

providersOf :: Host -> Value -> IO Value
providersOf h req = do
  rs <- sortedRefs h
  cands <- concat <$> mapM forRef rs
  resolveCapability req (VList cands)
  where
    -- ASK WHETHER THE NAME IS A REF, do not assume it. A requirement
    -- name is a CAPABILITY name first (§11.1) and capability names are
    -- free-form, so @2fa@ and @my cap@ are legal ones that no ref could
    -- be called — and @canonRef@ RAISES on those, which made a
    -- perfectly legal document kill the host right here.
    rname = vget req "name"
    asref = if isStr rname then tryRef (asStr rname) else Nothing
    forRef r = do
      me <- findInst h r
      case me of
        Nothing -> return []
        Just t -> do
          st <- readIORef (iStatus t)
          if st /= "live"
            then return []
            else do
              pos <- readIORef (iPos t)
              let cand prov =
                    vset (vset (vset (VMap []) "ref" (VStr r)) "pos" (VNum pos)) "provides" prov
              -- A ref satisfies directly.
              if asref == Just r
                then return [cand (vset (VMap []) "name" rname)]
                else do
                  ps <- readIORef (iProvides t)
                  return [cand p | p <- vitems ps, same (vget p "name") rname]

unmetOf :: Host -> Inst -> IO Value
unmetOf h e = do
  opts <- readIORef (iOptions e)
  names <- forM (vitems (requirements opts)) $ \r ->
    if not (gatesActivation r)
      then return Nothing
      else do
        ps <- providersOf h r
        return (if vlen ps == 0 then Just (vget r "name") else Nothing)
  return (VList (catMaybes names))

-- | §11.4's always-reluctant selection, and the ONE place a provider is
-- chosen for a live instance. "A satisfied requirement is not re-bound
-- while it stays satisfied" is a statement about a REMEMBERED choice.
--
-- @remember@ is 'False' for the questions asked ABOUT an instance
-- rather than BY it — introspection must not create a binding.
chosen :: Host -> Inst -> Value -> Bool -> IO (Maybe String)
chosen h e req remember = do
  cands <- providersOf h req
  if vlen cands == 0
    then return Nothing
    else do
      sel <- readIORef (iSelected e)
      let name = asStr (vget req "name")
          heldv = vget sel name
          kept =
            isStr heldv && any (\c -> asStr (vget c "ref") == asStr heldv) (vitems cands)
      if kept
        then return (Just (asStr heldv))
        else do
          let first = asStr (vget (vat cands 0) "ref")
          when remember $ modifyIORef' (iSelected e) (\m -> vset m name (VStr first))
          return (Just first)

-- | The instance currently SELECTED for each of this one's
-- restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
-- capability (§11.1): the selected one going away restarts a @static@
-- consumer even though a survivor is available.
boundProviders :: Host -> Inst -> IO [String]
boundProviders h e = do
  opts <- readIORef (iOptions e)
  foldM one [] (vitems (requirements opts))
  where
    one acc r
      | not (restartsOnLoss r) = return acc
      | otherwise = do
          p <- chosen h e r False
          return (case p of Just x | x `notElem` acc -> acc ++ [x]; _ -> acc)

consumersOf :: Host -> String -> IO [String]
consumersOf h r = do
  rs <- sortedRefs h
  fmap catMaybes $ forM rs $ \c ->
    if c == r
      then return Nothing
      else do
        me <- findInst h c
        case me of
          Nothing -> return Nothing
          Just ci -> do
            st <- readIORef (iStatus ci)
            if st /= "live"
              then return Nothing
              else do
                bp <- boundProviders h ci
                return (if r `elem` bp then Just c else Nothing)

-- | §11.3's @hold@ asks a DIFFERENT question from the cascade.
--
-- The cascade wants the edges that RESTART — mandatory-static and
-- optional-static. @hold@ says "deactivating a REQUIRED instance is
-- @plugin_dependency_held@", and @required@ is CARDINALITY:
-- 'gatesActivation', not 'restartsOnLoss'. The two sets differ in both
-- directions and each difference was a real bug.
holdersOf :: Host -> String -> IO [String]
holdersOf h r = do
  rs <- sortedRefs h
  fmap catMaybes $ forM rs $ \c ->
    if c == r
      then return Nothing
      else do
        me <- findInst h c
        case me of
          Nothing -> return Nothing
          Just ci -> do
            st <- readIORef (iStatus ci)
            if st /= "live"
              then return Nothing
              else do
                opts <- readIORef (iOptions ci)
                hits <- forM (vitems (requirements opts)) $ \req ->
                  if not (gatesActivation req)
                    then return False
                    else do
                      s <- chosen h ci req False
                      return (s == Just r)
                return (if or hits then Just c else Nothing)

-- | The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
-- COORDINATED TEARDOWN. In a bulk operation that is removing the
-- holders too, it is suspended — otherwise @close()@ under @hold@ would
-- raise on the first provider it reached whenever a document happened
-- to list a consumer after it, which is the policy refusing the one
-- teardown it has no reason to object to.
held :: Host -> Inst -> IO ()
held h e = do
  coord <- readIORef (hCoordinated h)
  when (hDependency h == "hold" && not coord) $ do
    holders <- holdersOf h (iRef e)
    unless (null holders) $
      raise "plugin_dependency_held" ("instance is required by live consumers: " ++ iRef e)
        (vset (vset (VMap []) "ref" (VStr (iRef e))) "holders" (VList (map VStr holders)))

-- | The requirement graph as plain data, for the pure detector.
graphNodes :: Host -> IO Value
graphNodes h = do
  rs <- sortedRefs h
  VList . catMaybes <$> mapM one rs
  where
    one r = do
      me <- findInst h r
      case me of
        Nothing -> return Nothing
        Just e -> do
          ps <- readIORef (iProvides e)
          opts <- readIORef (iOptions e)
          return $
            Just
              ( vset (vset (vset (VMap []) "ref" (VStr r))
                        "provides" (VList (map (`vget` "name") (vitems ps))))
                  "requires" (requirements opts) )

-- ---------------------------------------------------------------------
-- ordering and points
-- ---------------------------------------------------------------------

hostOrder :: Host -> String -> IO Value
hostOrder h point = do
  -- Sorted by declaration SEQUENCE, which is what makes the §7 sort's
  -- fall-through deterministic in a language whose containers have no
  -- insertion order. §7 breaks ties by @pos@; two instances CAN share
  -- one — @declare@ defaults @pos@ to the registry size, so an unload
  -- followed by a fresh declare reuses a surviving instance's — and
  -- past that the canonical was falling through to map order. @seq@ is
  -- that order, made explicit. Found by review of the go port.
  xs <- readIORef (hInstances h)
  live <- filterM' (\e -> (== "live") <$> readIORef (iStatus e)) xs
  bindings <- mapM one (sortBy (\a b -> compare (iSeq a) (iSeq b)) live)
  let spec = if null point then VNull else vget (hPoints h) point
  resolveOrder (VList bindings) (if isMap spec then vget spec "pin" else VNull)
  where
    one e = do
      pos <- readIORef (iPos e)
      ord <- readIORef (iOrder e)
      let b = vset (vset (VMap []) "ref" (VStr (iRef e))) "pos" (VNum pos)
      return (if isNull ord then b else vset b "order" ord)

positionOf :: Host -> String -> String -> IO Value
positionOf h r0 point = do
  ranked <- hostOrder h point
  r <- canonRefS r0
  let idx = case [i | (i, v) <- zip [0 ..] (vitems ranked), asStr v == r] of
        (i : _) -> fromIntegral (i :: Int)
        [] -> -1 :: Double
      n = fromIntegral (vlen ranked) :: Double
  -- §6.2 composes @b1(b2(b3(base)))@ with the FIRST binding OUTERMOST,
  -- so these are not index 0 and count-1 the other way round. Getting
  -- this backwards is the exact error the positional pin vocabulary
  -- exists to prevent.
  return
    ( vset (vset (vset (vset (VMap []) "index" (VNum idx)) "count" (VNum n))
              "outermost" (VBool (idx == 0)))
        "innermost" (VBool (idx == n - 1)) )

-- | Live bindings on a point, in resolved order. Recomputed on any
-- change to the live set (§7) rather than cached at startup — the bug a
-- host discovers only when something deactivates in production.
boundOn :: Host -> String -> IO [Bound]
boundOn h point = do
  ranked <- hostOrder h point
  concat <$> mapM one (vitems ranked)
  where
    one rv = do
      me <- findInst h (asStr rv)
      case me of
        Nothing -> return []
        Just e -> do
          -- The band is the INSTANCE's ordering block (§7), stamped by
          -- the host. A plugin passing its own would be ranking itself
          -- above the order its document declared.
          ord <- readIORef (iOrder e)
          let band = let x = vget ord "band" in if isNum x then asNum x else 0
          bs <- readIORef (iBindings e)
          return [b {bBand = band} | b <- bs, bPoint b == point]

pointSpec :: Host -> String -> IO Value
pointSpec h point = do
  unless (vhas (hPoints h) point) $
    raise "plugin_point_unknown" ("no such point: " ++ point) (details1 "point" (VStr point))
  let spec = vget (hPoints h) point
  return (if isMap spec then spec else VMap [])

checkKind :: Value -> String -> String -> IO ()
checkKind spec point want =
  unless ok $
    raise "plugin_point_kind" ("point is not a " ++ want ++ ": " ++ point)
      (vset (vset (VMap []) "point" (VStr point)) "kind" (if given then kind else VNull))
  where
    kind = vget spec "kind"
    given = isStr kind
    ok = if given then asStr kind == want else want == "hook"

hostEmit :: Host -> String -> Value -> IO (Maybe Value)
hostEmit h point arg = do
  spec <- pointSpec h point
  checkKind spec point "hook"
  bindings <- boundOn h point
  let mode = let m = vget spec "mode" in if isStr m then asStr m else "emit"
  (out, errors) <- pointEmit bindings mode arg
  return $ case mode of
    "emit" -> Nothing
    "bail" -> out
    _ -> Just errors

hostCall :: Host -> String -> Value -> IO Value
hostCall h point arg = do
  spec <- pointSpec h point
  checkKind spec point "chain"
  bindings <- boundOn h point
  -- The host owns the base and a plugin cannot replace it (§6.2). One
  -- that wants to SUBSTITUTE rather than wrap binds innermost and
  -- simply does not call @next@.
  pointCall bindings (lookup point (hBases h)) arg

hostProvider :: Host -> String -> Value -> IO (Maybe Value)
hostProvider h point arg = do
  spec <- pointSpec h point
  checkKind spec point "provider"
  bindings <- boundOn h point
  (winner, _) <- pointProvider bindings (truthy (vget spec "exclusive"))
  case winner of
    Nothing -> return (Just (vget spec "default"))
    Just b -> callHook b arg

hostShadowed :: Host -> String -> IO Value
hostShadowed h point
  | not (vhas (hPoints h) point) = return (VList [])
  | otherwise = do
      let spec = vget (hPoints h) point
      bindings <- boundOn h point
      (_, sh) <- pointProvider bindings (isMap spec && truthy (vget spec "exclusive"))
      return sh

hostExports :: Host -> String -> IO (Maybe Value)
hostExports h spec = do
  rs <- sortedRefs h
  all' <- concat <$> mapM one rs
  resolveExport (VStr spec) (VList all')
  where
    one r = do
      me <- findInst h r
      case me of
        Nothing -> return []
        Just e -> do
          st <- readIORef (iStatus e)
          -- Exports of a @loaded@ (not live) instance are VISIBLE
          -- (§11).
          if st == "declared" || st == "failed"
            then return []
            else do
              ex <- readIORef (iExports e)
              return
                [ vset (vset (vset (VMap []) "ref" (VStr r)) "key" (VStr k)) "value" (vget ex k)
                | k <- vkeys ex ]

hostCapability :: Host -> String -> IO Value
hostCapability h name = do
  rs <- sortedRefs h
  cands <- concat <$> mapM one rs
  ranked <- resolveCapability (vset (VMap []) "name" (VStr name)) (VList cands)
  return (VList (map (`vget` "ref") (vitems ranked)))
  where
    one r = do
      me <- findInst h r
      case me of
        Nothing -> return []
        Just e -> do
          st <- readIORef (iStatus e)
          if st /= "live"
            then return []
            else do
              pos <- readIORef (iPos e)
              ps <- readIORef (iProvides e)
              return
                [ vset (vset (vset (VMap []) "ref" (VStr r)) "pos" (VNum pos)) "provides" p
                | p <- vitems ps, isStr (vget p "name"), asStr (vget p "name") == name ]

-- ---------------------------------------------------------------------
-- the state machine
-- ---------------------------------------------------------------------

-- | AUTO-TAGGING IS EXPLICIT (§4 rule 3): the LOWEST UNUSED POSITIVE
-- INTEGER tag. It needs a host because it must know what is already
-- declared, which is why it cannot live in the pure @ref@ section.
autoTag :: Host -> String -> IO String
autoTag h name = go (1 :: Int)
  where
    go n = do
      cand <- formatRef (VStr name) (VStr (show n))
      me <- findInst h cand
      if isNothing me then return cand else go (n + 1)

hostDeclare :: Host -> String -> DeclareSpec -> IO Inst
hostDeclare h r0 spec = do
  r <-
    if sTag spec == "?"
      then canonRefS r0 >>= autoTag h . refName
      else canonRefS r0
  unless (sHostOwned spec) $ checkReservedH h r

  let defname = if null (sDefinition spec) then refName r else sDefinition spec
  mdef <- catalogGet (hCatalog h) defname
  def <- case mdef of
    Just d -> return d
    Nothing ->
      raise "plugin_unknown_definition" ("not in catalog: " ++ defname)
        (details1 "name" (VStr defname))

  existing <- findInst h r
  case existing of
    -- §4 rule 1: a pair addresses at most one instance. Re-declaring
    -- the SAME definition is the idempotent case; a different one is a
    -- duplicate, not a silent overwrite (seneca) and not an
    -- impossibility (sdkgen).
    Just e -> do
      when (dName (iDef e) /= dName def) $
        raise "plugin_ref_duplicate" ("instance already declared: " ++ r)
          (details1 "ref" (VStr r))
      return e
    Nothing -> do
      n <- length <$> readIORef (hInstances h)
      sq <- readIORef (hSeqn h)
      writeIORef (hSeqn h) (sq + 1)
      status <- newIORef "declared"
      pos <- newIORef (fromMaybe (fromIntegral n) (sPos spec))
      -- NO OPTIONS ADOPTED HERE. @apply@ resolves options and hands the
      -- map over; adopting the caller's map made target and source THE
      -- SAME MAP in the refill that follows, which cleared its own
      -- source and left a first-time instance with no options at all.
      -- Immutable values make that impossible here, and the rule is
      -- kept anyway so the ports read alike.
      opts <- newIORef (case sOptions spec of Just o | isMap o -> o; _ -> VMap [])
      state <- newIORef (VMap [])
      ord <- newIORef (sOrder spec)
      sel <- newIORef (VMap [])
      barred <- newIORef False
      unmet <- newIORef (VList [])
      scope <- newIORef []
      binds <- newIORef []
      inner <- newIORef Nothing
      exps <- newIORef (VMap [])
      provs <- newIORef (VList [])
      let e =
            Inst r def status pos sq opts state ord sel barred unmet scope binds
              inner exps provs h
      modifyIORef' (hInstances h) (++ [e])
      return e

hostLoad :: Host -> String -> DeclareSpec -> IO Inst
hostLoad h r spec = do
  guardHost h
  e <- hostDeclare h r spec
  st <- readIORef (iStatus e)
  if st /= "declared"
    then return e -- idempotent
    else do
      -- PRESENT AND NOT NULL, not merely present. Every driver builds
      -- its command spec with all four keys and a null for each absent
      -- one, so a presence test reads an omitted @options@ as an
      -- authored empty and wipes the real ones.
      case sOptions spec of
        Just o | isMap o -> writeIORef (iOptions e) o
        _ -> return ()

      failOn e (runCb h e "define")
      writeIORef (iStatus e) "loaded"

      -- AT LOAD, and before anything runs: a cycle through
      -- restart-causing requirements does not settle, and the only safe
      -- time to report a non-terminating reconcile is before it starts
      -- (§11.3). @provides@ is populated by @define@, which has just
      -- run, so this is the first moment the graph is complete.
      failOn e (graphNodes h >>= checkCycle)
      return e
  where
    failOn e act = act `catch` \err -> do
      writeIORef (iStatus e) "failed"
      throwIO (err :: PluginError)

-- | CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
--
-- The cascade is part of the provider's own deactivation and runs
-- BEFORE the provider's @deactivate@ callback and scope unwind, so a
-- consumer's teardown can still call the thing it depends on — flushing
-- a buffer to the store it is about to lose is exactly what a
-- @deactivate@ callback is for.
cascade :: Host -> Inst -> IORef [String] -> IO ()
cascade h provider seen = do
  s <- readIORef seen
  unless (iRef provider `elem` s) $ do
    modifyIORef' seen (iRef provider :)
    cons <- consumersOf h (iRef provider)
    forM_ cons $ \cref -> do
      mc <- findInst h cref
      case mc of
        Nothing -> return ()
        Just c -> do
          st <- readIORef (iStatus c)
          when (st == "live") $ do
            cascade h c seen -- deepest-first
            bad <- (runCb h c "deactivate" >> return False)
                     `catch` \e -> let _ = (e :: PluginError) in return True
            errors <- unwind h c
            if bad || vlen errors > 0
              -- §5.2: ANY failure during a transition lands the
              -- instance in @failed@, and a cascaded consumer is not an
              -- exception. Marking it @pending@ instead handed it
              -- straight back to @reconcile@, which would activate it
              -- again the moment the provider returned — the one thing
              -- @failed@ exists to stop.
              then writeIORef (iStatus c) "failed"
              else do
                writeIORef (iStatus c) "pending"
                unmetOf h c >>= writeIORef (iUnmet c)

hostActivate :: Host -> String -> IO Inst
hostActivate h r = do
  guardHost h
  e <- need h r
  st <- readIORef (iStatus e)
  if st == "live"
    then return e -- no-op returning success
    else do
      when (st == "failed") $
        raise "plugin_bad_state" ("instance has failed: " ++ iRef e)
          (details1 "ref" (VStr (iRef e)))
      -- §9.6: @active: false@ bars the instance from running, and the
      -- bar is on the INSTANCE rather than on the apply that set it.
      -- @ready@ reaches this through @activate@, which is why one guard
      -- covers both verbs the design names.
      barred <- readIORef (iBarred e)
      when barred $
        raise "plugin_inactive" ("instance is barred by active: false: " ++ iRef e)
          (details1 "ref" (VStr (iRef e)))
      when (st == "declared") $ () <$ hostLoad h (iRef e) noSpec

      -- A declared requirement that is not live means @pending@:
      -- activation is a STANDING REQUEST, not a one-shot event.
      unmet <- unmetOf h e
      if vlen unmet > 0
        then do
          writeIORef (iUnmet e) unmet
          writeIORef (iStatus e) "pending"
          return e
        else do
          runCb h e "activate" `catch` \err -> do
            -- Unwind whatever the partial activation captured, in
            -- reverse.
            _ <- unwind h e
            writeIORef (iStatus e) "failed"
            throwIO (err :: PluginError)
          -- §11.4: THE SELECTION IS MADE HERE, once, and remembered.
          -- Every later question — the cascade, @hold@, @unmet@ — reads
          -- it back rather than re-ranking, which is what
          -- "always-reluctant" means.
          opts <- readIORef (iOptions e)
          forM_ (vitems (requirements opts)) $ \req -> chosen h e req True
          writeIORef (iStatus e) "live"
          reconcile h
          return e

hostDeactivate :: Host -> String -> IO Inst
hostDeactivate h r = do
  guardHost h
  e <- need h r
  st <- readIORef (iStatus e)
  if st == "loaded" || st == "declared"
    then return e
    else do
      -- §5.2: @unload@ is THE ONLY TRANSITION OUT OF @failed@. Falling
      -- through here ran the definition's @deactivate@ on an instance
      -- that never completed activation and, if that callback happened
      -- to succeed, returned it to @loaded@ — from where it could be
      -- activated again, which is precisely what @failed@ exists to
      -- prevent.
      when (st == "failed") $
        raise "plugin_bad_state" ("instance has failed: " ++ iRef e)
          (details1 "ref" (VStr (iRef e)))
      if st == "pending"
        then do
          -- DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
          -- never reached activate, so it holds no scope and no live
          -- bindings; running the definition's deactivate there would
          -- be teardown without matching setup. It cannot fail.
          writeIORef (iStatus e) "loaded"
          writeIORef (iUnmet e) (VList [])
          return e
        else do
          held h e
          seen <- newIORef []
          cascade h e seen
          runCb h e "deactivate" `catch` \err -> do
            _ <- unwind h e
            writeIORef (iStatus e) "failed"
            throwIO (err :: PluginError)
          unwind h e >>= releaseCheck e
          writeIORef (iStatus e) "loaded"
          reconcile h
          return e

hostUnload :: Host -> String -> IO ()
hostUnload h r = do
  guardHost h
  e <- need h r
  st <- readIORef (iStatus e)
  when (st == "live" || st == "pending") $ do
    when (st == "live") $ do
      held h e
      seen <- newIORef []
      cascade h e seen
      runCb h e "deactivate" `catch` \err -> do
        -- §5.2: ANY failure during a transition lands the instance in
        -- @failed@, with the scope STILL FULLY UNWOUND. An earlier
        -- draft let the raise propagate straight out of @unload@, which
        -- left the instance @live@ and its scope untouched — reporting
        -- a failure while leaking exactly the resources the failure was
        -- about.
        _ <- unwind h e
        writeIORef (iStatus e) "failed"
        throwIO (err :: PluginError)
      unwind h e >>= releaseCheck e
    writeIORef (iStatus e) "loaded"
  st2 <- readIORef (iStatus e)
  let drop' = modifyIORef' (hInstances h) (filter ((/= iRef e) . iRef))
  when (st2 == "loaded" || st2 == "failed") $
    runCb h e "close" `catch` \err -> do
      drop'
      throwIO (err :: PluginError)
  drop'

hostReady :: Host -> String -> IO Inst
hostReady h r0 = do
  -- Runs the whole forward path in one call (§5.1). §15.2's verb list
  -- omits this; §5.1 defines it and §15.3's @declare@ row requires the
  -- corpus to pin it, so the list was incomplete rather than excluding
  -- it (DOCS.md §4.2).
  guardHost h
  r <- canonRefS r0
  me <- findInst h r
  when (isNothing me) $ () <$ hostDeclare h r noSpec
  me2 <- findInst h r
  case me2 of
    Just e -> do
      st <- readIORef (iStatus e)
      when (st == "declared") $ () <$ hostLoad h r noSpec
    Nothing -> return ()
  hostActivate h r

-- | EAGER reconciliation: run to a fixed point rather than scheduling.
--
-- Two directions, and both are the reason @pending@ exists. Activation
-- is a STANDING REQUEST, not a one-shot event: a pending instance whose
-- requirement arrives activates without being asked again, and a LIVE
-- instance whose requirement is lost goes back to pending —
-- recursively, through its own consumers.
reconcile :: Host -> IO ()
reconcile h = go (0 :: Int)
  where
    go rounds
      | rounds > 1000 = return ()
      | otherwise = do
          rs <- sortedRefs h
          -- Losses first, so a cascade settles in one pass rather than
          -- alternating with re-activations.
          m1 <- foldM lose False rs
          rs2 <- sortedRefs h
          m2 <- foldM gain False rs2
          when (m1 || m2) $ go (rounds + 1)

    lose moved r = do
      me <- findInst h r
      case me of
        Nothing -> return moved
        Just e -> do
          st <- readIORef (iStatus e)
          if st /= "live"
            then return moved
            else do
              opts <- readIORef (iOptions e)
              lost <- filterM' gone (filter gatesActivation (vitems (requirements opts)))
              -- POLICY IS PER REQUIREMENT, not per instance (§11.3):
              -- only the definition that has the requirement knows what
              -- it can cope with, and one instance may hold both a
              -- @static@ and a @dynamic@ one. A @dynamic@ requirement
              -- whose provider is gone leaves the consumer LIVE and
              -- notified.
              if null lost || not (any restartsOnLoss lost)
                then return moved
                else do
                  bad <- (runCb h e "deactivate" >> return False)
                           `catch` \err -> let _ = (err :: PluginError) in return True
                  errors <- unwind h e
                  if bad || vlen errors > 0
                    then writeIORef (iStatus e) "failed"
                    else do
                      writeIORef (iStatus e) "pending"
                      unmetOf h e >>= writeIORef (iUnmet e)
                  return True
      where
        gone q = (== 0) . vlen <$> providersOf h q

    gain moved r = do
      me <- findInst h r
      case me of
        Nothing -> return moved
        Just e -> do
          st <- readIORef (iStatus e)
          if st /= "pending"
            then return moved
            else do
              u <- unmetOf h e
              if vlen u > 0
                then return moved
                else do
                  ok <-
                    ( do
                        runCb h e "activate"
                        opts <- readIORef (iOptions e)
                        forM_ (vitems (requirements opts)) $ \req -> chosen h e req True
                        writeIORef (iStatus e) "live"
                        writeIORef (iUnmet e) (VList [])
                        return True )
                      `catch` \err -> let _ = (err :: PluginError) in return False
                  unless ok $ do
                    _ <- unwind h e
                    writeIORef (iStatus e) "failed"
                  return True

hostClose :: Host -> IO ()
hostClose h = do
  -- A bulk teardown removing the holders too, so @hold@ is suspended
  -- for exactly those holders (§11.3) — while the consumers-first
  -- cascade still runs, which is the half that matters.
  -- A COORDINATED FLAG THAT SURVIVES A RAISE IS A DISABLED GUARD. The
  -- canonical wraps the teardown in @try@/@finally@; an unload that
  -- raises would skip the reset and leave the host permanently
  -- @coordinated@, so a caller that catches the error and carries on
  -- under @dependency: "hold"@ gets ad-hoc deactivation with the holder
  -- check silently off.
  writeIORef (hCoordinated h) True
  xs <- readIORef (hInstances h)
  keyed <- mapM (\e -> do p <- readIORef (iPos e); return (p, iRef e)) xs
  -- Reverse load order: highest @pos@ first, ref-descending for a tie,
  -- so a consumer declared after its provider goes down first.
  let refs = map snd (sortBy (\a b -> compare b a) keyed)
  let teardown = forM_ refs $ \r -> do
        me <- findInst h r
        when (not (isNothing me)) $ hostUnload h r
  teardown `finally` writeIORef (hCoordinated h) False

-- | AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS THE
-- INNER ONE'S LIFETIME. Registering the teardown in the instance scope
-- is what makes that true rather than aspirational: the inner host
-- closes when the outer instance deactivates, in the same reverse
-- unwind as every other resource.
--
-- It does NOT count toward @open@ — a teardown is not an acquisition
-- (@nest\/open@).
instNest :: Inst -> HostOptions -> IO Host
instNest e opts = do
  t <- readIORef (hInTransition (iOwner e))
  unless t $
    raise "plugin_release_scope" "nest called outside a lifecycle callback" (VMap [])
  inner <- makeHost opts
  d <- newIORef False
  modifyIORef' (iScope e) (++ [ScopeEntry (Just (hostClose inner)) d False])
  writeIORef (iInner e) (Just inner)
  return inner

-- ---------------------------------------------------------------------
-- documents
-- ---------------------------------------------------------------------

shapeOf :: Host -> String -> IO Value
shapeOf h r = maybe VNull dShape <$> catalogGet (hCatalog h) (refName r)

hostApply :: Host -> Value -> Value -> IO ()
hostApply h doc profile = do
  guardHost h
  let inp =
        vset (vset (vset (vset (VMap []) "doc" doc)
                      "profile" (if isNull profile then hProfile h else profile))
                "keys" (hKeys h))
          "reserved" (hReserved h)
  norm <- normalizeConfig inp
  let want = map asStr (vitems (vget norm "order"))
      instancespec = vget norm "instance"
      wantlive ent =
        isMap ent && truthy (vget ent "active") && asStr (vget ent "start") == "eager"

  optionsof <- foldM (resolveFor doc profile) (VMap []) want

  -- --- phase 1: deactivations and unloads, in REVERSE load order ---
  xs <- readIORef (hInstances h)
  dropping <- fmap catMaybes $ forM xs $ \e -> do
    st <- readIORef (iStatus e)
    p <- readIORef (iPos e)
    return $
      if st /= "declared" && not (wantlive (vget instancespec (iRef e)))
        then Just (p, iRef e)
        else Nothing
  -- Reverse load order: highest @pos@ first, ref-descending for a tie,
  -- so a consumer declared after its provider goes down first.
  forM_ (map snd (sortBy (\a b -> compare b a) dropping)) (hostUnload h)

  -- --- phase 2: declare and patch EVERYTHING, in load order --------
  forM_ want $ \r -> do
    let ent = vget instancespec r
    e <-
      hostDeclare h r
        noSpec {sOrder = vget ent "order", sPos = Just (asNum (vget ent "pos"))}
    -- The bar is REASSERTED ON EVERY APPLY, in both directions — a
    -- document that turns the instance back on clears it, which is the
    -- whole point of a config switch.
    writeIORef (iBarred e) (not (truthy (vget ent "active")))
    -- Where the other ports must refill the options map IN PLACE so
    -- callbacks that closed over it see the new values, this port's
    -- callbacks read the ref, so a write is the same observation.
    writeIORef (iOptions e) (vget optionsof r)
    writeIORef (iOrder e) (vget ent "order")
    writeIORef (iPos e) (asNum (vget ent "pos"))

  -- --- phase 3: loads, then phase 4: activations, in load order ----
  forM_ want $ \r ->
    when (wantlive (vget instancespec r)) $ () <$ hostLoad h r noSpec
  forM_ want $ \r ->
    when (wantlive (vget instancespec r)) $ () <$ hostActivate h r
  where
    resolveFor doc' profile' acc r = do
      shape <- shapeOf h r
      let oin =
            vset (vset (vset (vset (VMap []) "ref" (VStr r)) "doc" doc')
                    "profile" (if isNull profile' then hProfile h else profile'))
              "shape" shape
          oin2 =
            if isMap (hDefaults h)
              then vset oin "hostdefaults" (vget (hDefaults h) (refName r))
              else oin
      o <- resolveOptions oin2
      return (vset acc r o)

hostSetOptions :: Host -> String -> Value -> IO ()
hostSetOptions h r patch = do
  guardHost h
  e <- need h r
  previous <- readIORef (iOptions e)
  shape <- shapeOf h (iRef e)
  let inp =
        vset (vset (vset (vset (VMap []) "ref" (VStr (iRef e))) "shape" shape)
                "doc" (VMap []))
          "patch" (mergeValue previous patch)
  resolveOptions inp >>= writeIORef (iOptions e)

  st <- readIORef (iStatus e)
  when (st == "live") $
    case dReconfigure (iDef e) of
      Just f -> do
        writeIORef (hInTransition h) True
        writeIORef (hPhase h) "reconfigure"
        opts <- readIORef (iOptions e)
        res <- try (f e opts previous)
        writeIORef (hInTransition h) False
        writeIORef (hPhase h) ""
        either (throwIO :: SomeException -> IO ()) return res
      Nothing -> do
        -- Always correct and sometimes expensive; @reconfigure@ exists
        -- to make the common case cheap (§9.4).
        _ <- hostDeactivate h (iRef e)
        _ <- hostActivate h (iRef e)
        return ()

filterM' :: (a -> IO Bool) -> [a] -> IO [a]
filterM' _ [] = return []
filterM' p (x : xs) = do
  keep <- p x
  rest <- filterM' p xs
  return (if keep then x : rest else rest)
