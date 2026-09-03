-- | The driver (DOCS.md §4).
--
-- Every port implements this same small thing and nothing else is
-- port-specific: the probe catalog, the command interpreter, and the
-- canonical observable.
--
-- A PROBE'S CALLBACKS ARE CLOSURES OVER THE INSTANCE, the way the
-- canonical writes them — Haskell has closures, so unlike `c` there is
-- no context pointer to thread.

module Driver (driverProbes, driverProbe, driverSeed, buildOptions, drive) where

import Control.Exception (catch, throwIO)
import Control.Monad (foldM, forM_, unless, when)
import Data.IORef
import Defs
import Host
import Point
import Types
import Value

-- --- probe helpers -----------------------------------------------------

opt :: Inst -> String -> IO Value
opt i key = (`vget` key) <$> readIORef (iOptions i)

numOf :: Value -> Double
numOf v = if isNum v then asNum v else 0

bumpState :: Inst -> Double -> IO ()
bumpState i start = do
  st <- readIORef (iState i)
  unless (vhas st "count") $ writeIORef (iState i) (vset st "count" (VNum start))

addCount :: Inst -> IO ()
addCount i = modifyIORef' (iState i) (\st -> vset st "count" (VNum (numOf (vget st "count") + 1)))

-- | @noisy@ fails on demand: @options.fail@ names the callback that
-- raises and @options.code@ the error code. @options.bare@ raises with
-- NO CODE AT ALL, which is the ordinary library error §12's
-- @plugin_<phase>_failed@ codes exist to wrap.
boom :: Inst -> String -> IO ()
boom i cb = do
  f <- opt i "fail"
  when (isStr f && asStr f == cb) $ do
    let text = "probe failed at " ++ cb
    bare <- opt i "bare"
    -- 'raise' needs a code, so the bare case uses a sentinel the host
    -- recognises and wraps, which is what every other port gets from a
    -- plain language error.
    when (truthy bare) $ raise "plugin_bare" text (VMap [])
    code <- opt i "code"
    raise (if isStr code then asStr code else "plugin_" ++ cb ++ "_failed") text (VMap [])

reenter :: Inst -> String -> IO ()
reenter i cb = do
  r <- opt i "reenter"
  -- A transition from inside a lifecycle callback: §5.2's
  -- @plugin_reentrant@, reached by actually attempting one.
  when (isStr r && asStr r == cb) $ () <$ hostActivate (iOwner i) (iRef i)

-- --- the `probe` bindings ----------------------------------------------

bindProbe :: Inst -> IO ()
bindProbe i = do
  band <- opt i "band"
  -- One hook binding (@p@) and one chain wrap (@c@) — the workhorse
  -- shape DOCS.md §4.3 specifies.
  instBindHook i "p" (\_ -> do addCount i; return Nothing) band
  -- @p@ RETURNS NOTHING, as the canonical's arrow-with-a-block does: in
  -- @bail@ mode a return is an answer, and a counter that answered with
  -- its own count would make every hook that keeps one un-bailable.
  instBindChain i "c" (chainWrap i) band

chainWrap :: Inst -> Next -> Value -> IO Value
chainWrap i next arg = do
  wrap <- opt i "wrap"
  let w = if isStr wrap then asStr wrap else ":"
  inner <- next arg
  let tail' = if isStr inner then asStr inner else if isNull inner then "" else renderJson inner
  -- Wrap AFTER next, so the result spells the nesting left to right:
  -- outermost first. Wrapping the ARGUMENT instead would spell it
  -- backwards and make every chain expectation read wrong.
  return (VStr (w ++ tail'))

-- --- the base points every driver host declares ------------------------

-- | DOCS.md §4.3 defines @probe@ as binding one hook point (@p@) and
-- wrapping one chain point (@c@), so a host without them cannot load
-- the probe at all — they are part of the contract's baseline rather
-- than a fixture convenience. @v@ is the provider point the @provider@
-- probe defaults to.
buildOptions :: Value -> HostOptions
buildOptions cmd =
  noHostOptions
    { oPoints = points
    , oBases = bases
    , oReserved = vget cmd "reserved"
    , oKeys = vget cmd "keys"
    , oDefaults = vget cmd "defaults"
    , oProfile = vget cmd "profile"
    -- §11.3's strict reading. Absent means @restart@, which is the
    -- default precisely because a station that cannot swap a provider
    -- without a restart has lost the argument for having a plugin
    -- system.
    , oDependency = let d = vget cmd "dependency" in if isStr d then asStr d else ""
    }
  where
    kindMap k v = (k, vset (VMap []) "kind" (VStr v))
    base = foldl (\m (k, v) -> vset m k v) (VMap []) [kindMap "p" "hook", kindMap "c" "chain", kindMap "v" "provider"]
    extra = vget cmd "points"
    -- A @host@ command REPLACES a base point rather than merging into
    -- it, so an entry can redeclare @c@ with its own base or @v@ as
    -- exclusive without inheriting the default's shape.
    points = if isMap extra then foldl (\m k -> vset m k (vget extra k)) base (vkeys extra) else base
    -- Every chain point gets the identity base: the host owns it and a
    -- plugin cannot replace it (§6.2).
    bases =
      [ (k, return) | k <- vkeys points
      , let kd = vget (vget points k) "kind", isStr kd, asStr kd == "chain" ]

-- --- probe callbacks ---------------------------------------------------

probeDefine :: Inst -> IO ()
probeDefine i = do
  bumpState i 0
  boom i "define"
  bindProbe i
  instExport i "client" (VStr (iRef i))
  -- The instance api itself, so the driver's @stray@ command can call
  -- @release@ from OUTSIDE a lifecycle callback — which is the only way
  -- to exercise §8.3's scope guard. The driver looks the instance up by
  -- ref; this export keeps the shape the other ports have.
  instExport i "inst" (VStr (iRef i))
  provides <- opt i "provides"
  forM_ (vitems provides) (instProvides i)

probeActivate :: Inst -> IO ()
probeActivate i = do
  _ <- instAcquire i
  reenter i "activate"
  boom i "activate"
  -- §6.5: an instance that is itself a host. The outer owns the inner's
  -- lifetime — registered in the scope, so it closes on deactivate in
  -- the same reverse unwind as every other resource.
  nest <- opt i "nest"
  when (isList nest && vlen nest > 0) $ do
    inner <- instNest i (buildOptions VNull)
    driverSeed inner
    forM_ (vitems nest) $ \r -> hostReady inner (asStr r)

-- | @greedy@ acquires @options.acquire@ resources and releases
-- @options.release@ of them explicitly, so the difference is what the
-- instance scope must unwind (§8.3).
greedyCapture :: Inst -> IO ()
greedyCapture i = do
  acquireN <- round . numOf <$> opt i "acquire"
  releaseN <- round . numOf <$> opt i "release"
  -- Acquire N and hand back M, so the DIFFERENCE is what the instance
  -- scope must unwind (§8.3). Handing one back early must not make
  -- teardown wrong: the scope keeps the entry and unwinding it twice is
  -- a no-op.
  held' <- mapM (const (instAcquire i)) [1 .. acquireN :: Int]
  forM_ (take releaseN held') (instGiveback i)

  markN <- round . numOf <$> opt i "mark"
  markfail <- truthy <$> opt i "markfail"
  forM_ [0 .. markN - 1 :: Int] $ \k ->
    instRelease i . Just $ do
      st <- readIORef (iState i)
      let unwound = let u = vget st "unwound" in if isList u then u else VList []
      writeIORef (iState i) (vset st "unwound" (vpush unwound (VNum (fromIntegral k))))
      -- The only way §8.3's @plugin_release_failed@ and its @failed@
      -- status are reachable.
      when markfail $ raise "probe_release_boom" "release raised" (VMap [])

greedyDefine :: Inst -> IO ()
greedyDefine i = do
  bumpState i 0
  -- @options.early@ acquires in @define@ instead, where §8.1 says
  -- capture does not belong.
  early <- opt i "early"
  when (isStr early && asStr early == "acquire") $ () <$ instAcquire i
  when (isStr early && asStr early == "release") $ instRelease i Nothing
  bindv <- opt i "bind"
  band <- opt i "band"
  unless (isStr bindv) $ instBindHook i "p" (\_ -> do addCount i; return Nothing) band

-- | @options.bind@ names the callback that declares a BINDING outside
-- @define@, which is §8.1's other half and §12's @plugin_bind_scope@.
greedyBindAt :: Inst -> String -> IO ()
greedyBindAt i cb = do
  b <- opt i "bind"
  when (isStr b && asStr b == cb) $ instBindHook i "p" (\_ -> return Nothing) VNull

depDefine :: Inst -> IO ()
depDefine i = do
  modifyIORef' (iState i) (\st -> vset st "count" (VNum 0))
  provides <- opt i "provides"
  forM_ (vitems provides) (instProvides i)
  exports <- opt i "exports"
  when (isMap exports) $ forM_ (vkeys exports) $ \k -> instExport i k (vget exports k)

providerDefine :: Inst -> IO ()
providerDefine i = do
  modifyIORef' (iState i) (\st -> vset st "count" (VNum 0))
  point <- opt i "point"
  band <- opt i "band"
  instBindHook i (if isStr point then asStr point else "v") answer band
  provides <- opt i "provides"
  when (isList provides) $ forM_ (vitems provides) (instProvides i)
  where
    answer _ = do
      -- PRESENCE, not non-null. An authored @value: null@ IS a value —
      -- and in @bail@ mode a null DECLINES and the next binding
      -- answers, which is what @point\/bail#null-declines@ pins.
      -- Reading it as "no value given" and substituting the ref made
      -- this probe answer where the contract says it stands aside.
      opts <- readIORef (iOptions i)
      return (Just (if vhas opts "value" then vget opts "value" else VStr (iRef i)))

-- | §4.3's six probes, plus the @record@ family the corpus names. Their
-- behaviour is as much the contract as the runner is — this is where
-- twenty implementations of @noisy@ are made to fail at the same
-- callback in the same way.
probeDef :: String -> Definition
probeDef name = case name of
  n | n == "probe" || n == "noisy" ->
        base
          { dDefine = Just probeDefine
          , dActivate = Just probeActivate
          , dDeactivate = Just (`boom` "deactivate")
          , dClose = Just (`boom` "close")
          }
  "greedy" ->
    base
      { dDefine = Just greedyDefine
      , dActivate = Just (\i -> greedyCapture i >> greedyBindAt i "activate")
      , dDeactivate = Just (`greedyBindAt` "deactivate")
      }
  "dep" -> base {dDefine = Just depDefine}
  "provider" -> base {dDefine = Just providerDefine}
  _ -> base
  where
    base =
      Definition
        { dName = name
        , dShape = VNull
        , dDefine = Just (`bumpState` 0)
        , dActivate = Just (\i -> () <$ instAcquire i)
        , dDeactivate = Nothing
        , dClose = Nothing
        , dReconfigure = Nothing
        }

probeNames :: [String]
probeNames = ["probe", "noisy", "greedy", "dep", "provider", "slow", "other", "adapter", "late"]

driverProbes :: Value
driverProbes = VList (map VStr probeNames)

driverProbe :: String -> Maybe Definition
driverProbe name = if name `elem` probeNames then Just (probeDef name) else Nothing

-- | Register the whole probe set into a host's catalog.
driverSeed :: Host -> IO ()
driverSeed h = forM_ probeNames (hostDefine h . probeDef)

-- --- the command interpreter -------------------------------------------

declSpec :: Value -> DeclareSpec
declSpec cmd =
  noSpec
    -- PRESENT AND NOT NULL. Every driver builds its spec with all four
    -- keys and a null for each absent one, so a presence test reads an
    -- omitted @options@ as an authored empty and wipes the real ones.
    { sOptions = if isMap options then Just options else Nothing
    , sOrder = vget cmd "order"
    , sDefinition = asStr (vget cmd "definition")
    , sTag = asStr (vget cmd "tag")
    }
  where
    options = vget cmd "options"

-- | One command. Answers @(host, result)@, where the result is @Just v@
-- when the verb yields one; §4.5 makes @result@ the value of THE LAST
-- COMMAND THAT PRODUCES ONE, so "produced nothing" and "produced null"
-- have to stay distinguishable.
docmd :: Host -> Value -> IO (Host, Maybe Value)
docmd h cmd = case verb of
  "host" -> do
    fresh <- makeHost (buildOptions cmd)
    driverSeed fresh
    return (fresh, Nothing)
  "define" -> do
    -- §10.1's static registration: the definition ENTERS THE CATALOG
    -- here, and registration is where its option shape is validated
    -- (§9.4) — before any load, so a malformed shape fails at one
    -- moment in every host rather than whenever a document happens to
    -- exercise the key.
    --
    -- §4.2's three keys, all of them live. @probe@ names the PROBE
    -- whose callbacks back the definition and @name@ is what the
    -- definition is called.
    let name = asStr (vget cmd "name")
        from = let p = asStr (vget cmd "probe") in if null p then name else p
        base = case driverProbe from of
          Just b -> b {dName = name}
          Nothing -> Definition name VNull Nothing Nothing Nothing Nothing Nothing
        def = if vhas cmd "shape" then base {dShape = vget cmd "shape"} else base
    hostDefine h def
    none
  "load" -> hostLoad h ref spec >> none
  "ready" -> do
    -- declare FIRST, so the ordering block and definition reach the
    -- instance — @ready@ walks the staircase, it does not carry
    -- configuration of its own.
    _ <- hostDeclare h ref spec
    _ <- hostReady h ref
    none
  "activate" -> hostActivate h ref >> none
  "deactivate" -> hostDeactivate h ref >> none
  "unload" -> hostUnload h ref >> none
  "close" -> hostClose h >> none
  "apply" -> hostApply h (vget cmd "doc") (vget cmd "profile") >> none
  "options" -> hostSetOptions h ref (vget cmd "patch") >> none
  "declare" -> hostDeclare h ref spec >>= yields . VStr . iRef
  -- §9.1's host-owned path: the embedding host installing the instance
  -- whose name it reserved.
  "hostdeclare" -> hostDeclare h ref spec {sHostOwned = True} >>= yields . VStr . iRef
  "list" -> hostList h >>= yields
  "emit" -> hostEmit h point (vget cmd "arg") >>= yieldsMaybe
  "chain" -> hostCall h point (vget cmd "arg") >>= yields
  "provider" -> hostProvider h point (vget cmd "arg") >>= yieldsMaybe
  "shadowed" -> hostShadowed h point >>= yields
  "export" -> hostExports h (asStr (vget cmd "key")) >>= yieldsMaybe
  "capability" -> hostCapability h (asStr (vget cmd "name")) >>= yields
  "trace" -> hostTrace h >>= yields
  "order" -> hostOrder h point >>= yields
  "seq" -> withInst (fmap (VNum . iSeq) . return) >>= yields
  "pos" -> do
    me <- hostInstance h ref
    maybe (yields VNull) (\e -> readIORef (iPos e) >>= yields . VNum) me
  "inner" -> do
    me <- hostInstance h ref
    case me of
      Nothing -> yields VNull
      Just e -> do
        mi <- readIORef (iInner e)
        maybe (yields VNull) (\i -> hostList i >>= yields) mi
  "call" -> do
    me <- hostInstance h ref
    case me of
      Nothing -> raise "plugin_not_loaded" ("no such instance: " ++ ref) (VMap [])
      Just e -> callMethod e
  _ -> raise "plugin_bad_state" ("unknown driver command: " ++ verb) (VMap [])
  where
    verb = asStr (vget cmd "do")
    ref = asStr (vget cmd "ref")
    point = asStr (vget cmd "point")
    spec = declSpec cmd
    none = return (h, Nothing)
    yields v = return (h, Just v)
    yieldsMaybe = yields . maybe VNull id
    withInst f = do
      me <- hostInstance h ref
      maybe (return VNull) f me

    callMethod e = case asStr (vget cmd "method") of
      "" -> none
      "bump" -> addCount e >> none
      "count" -> do
        st <- readIORef (iState e)
        yields (VNum (numOf (vget st "count")))
      "unwound" -> do
        st <- readIORef (iState e)
        let u = vget st "unwound"
        yields (if isList u then u else VList [])
      -- Reached through the instance api, which is where §6.6 puts it —
      -- a plugin asks about itself.
      "position" -> instPosition e point >>= yields
      -- A release from OUTSIDE a lifecycle callback. The scope belongs
      -- to the activation; a call from anywhere else has no scope to
      -- belong to, so it raises.
      "stray" -> instRelease e Nothing >> none
      _ -> none

drive :: Value -> IO Value
drive cmds = do
  h0 <- makeHost (buildOptions VNull)
  driverSeed h0
  -- §4.5: @result@ is the value of THE LAST COMMAND THAT PRODUCES ONE.
  -- Storing it and continuing — rather than returning at the first
  -- producing command — is what lets an entry emit and then inspect,
  -- which most of @point@ needs.
  (h, last') <- foldM step (h0, Nothing) (vitems cmds)
  observable h last'
  where
    step (h, last') cmd =
      ( do
          (h', produced) <- docmd h cmd
          return (h', maybe last' Just produced) )
        `catch` \e ->
          -- §4.1: @catch@ records the raise and lets the run continue,
          -- which is the only way to observe a @failed@ instance —
          -- §5.2's whole claim is that it stays registered and
          -- inspectable.
          if truthy (vget cmd "catch")
            then return (h, last')
            else throwIO (e :: PluginError)
