-- | The mutually recursive types: a definition's callbacks take an
-- instance, an instance points at its host, and a host holds a catalog
-- of definitions.
--
-- THEY LIVE IN ONE MODULE BECAUSE HASKELL SAYS SO. Modules cannot be
-- mutually recursive without @.hs-boot@ files, and this cycle is real
-- rather than accidental — it is the same cycle `c` opens with a
-- forward @typedef struct Inst Inst;@ and `ocaml` gathers into
-- @defs.ml@. The functions over these types are split back out into
-- "Catalog" and "Host", so only the declarations are here.
--
-- THE MUTABILITY IS ON THE INSTANCE, NOT INSIDE THE VALUE. Every field
-- a transition changes is an 'IORef'; 'Value' itself stays immutable.
-- That is why this port needs no in-place @refill@: a callback reads
-- @iOptions@ through the ref each time, so replacing the value it holds
-- is the same observation the other ports get from emptying a map and
-- filling it again.

module Defs where

import Data.IORef (IORef)
import Point (Bound)
import Value

-- | A scope release: a closure, so an instance's teardown captures
-- whatever it needs rather than being handed a context pointer the way
-- `c` must.
type Release = IO ()

-- | @acquire@ hands one of these back so a plugin can release early;
-- the scope keeps the entry, and unwinding it twice is a no-op.
data ScopeEntry = ScopeEntry
  { seFn :: Maybe Release
  , seDone :: IORef Bool
  -- | @acquire@ and @release@ both count toward @open@; a nested host's
  -- teardown does NOT — a teardown is not an acquisition, and the inner
  -- host keeps its own counter (@nest\/open@).
  , seCounts :: Bool
  }

-- | A DEFINITION IS DATA WITH FUNCTIONS IN IT, not a class to extend. A
-- document could produce one, which is the property that makes a
-- catalog a data structure rather than a compile-time registry.
data Definition = Definition
  { dName :: String
  , dShape :: Value
  , dDefine :: Maybe (Inst -> IO ())
  , dActivate :: Maybe (Inst -> IO ())
  , dDeactivate :: Maybe (Inst -> IO ())
  , dClose :: Maybe (Inst -> IO ())
  , dReconfigure :: Maybe (Inst -> Value -> Value -> IO ())
  }

type Catalog = IORef [(String, Definition)]

data Inst = Inst
  { iRef :: String
  , iDef :: Definition
  , iStatus :: IORef String
  , iPos :: IORef Double
  , iSeq :: Double
  , iOptions :: IORef Value
  , iState :: IORef Value
  , iOrder :: IORef Value
  -- | §11.4's ALWAYS-RELUCTANT rebinding, made concrete: the provider
  -- ref this instance's activation actually selected, per requirement
  -- name. Recomputing the best candidate on every question silently
  -- re-points a live consumer at any better-ranked newcomer, and then
  -- losing the provider it was really using does not restart it.
  , iSelected :: IORef Value
  -- | §9.6's @active: false@. THE BAR OUTLIVES THE APPLY THAT SET IT: a
  -- flag consulted only while @apply@ ran let a later direct @ready@
  -- bring the instance live, which is the config switch it exists to be
  -- silently ignored.
  , iBarred :: IORef Bool
  , iUnmet :: IORef Value
  , iScope :: IORef [ScopeEntry]
  -- | Declared in @define@, inserted only when activation SUCCEEDS
  -- (§8.1). Holding them until then is what makes a failed activate
  -- leave nothing behind.
  , iBindings :: IORef [Bound]
  , iInner :: IORef (Maybe Host)
  -- | Declared in @define@, and VISIBLE while merely @loaded@ (§11):
  -- they are data, and hiding them would make the loaded state useless
  -- for introspection.
  , iExports :: IORef Value
  , iProvides :: IORef Value
  , iOwner :: Host
  }

data Host = Host
  { hCatalog :: Catalog
  , hReserved :: Value
  , hKeys :: Value
  , hDefaults :: Value
  , hProfile :: Value
  , hPoints :: Value
  , hBases :: [(String, Value -> IO Value)]
  -- | §11.3. @restart@ (the default) treats provider replacement as an
  -- ordinary runtime operation. @hold@ is the strict reading —
  -- deactivating a required instance is @plugin_dependency_held@. NOT
  -- the default, because a station that cannot swap a provider without
  -- a restart has lost the argument for having a plugin system.
  , hDependency :: String
  -- | Set for the duration of a bulk teardown, so @held@ knows this is
  -- a coordinated operation rather than an ad-hoc deactivation.
  , hCoordinated :: IORef Bool
  , hInstances :: IORef [Inst]
  , hLog :: IORef Value
  , hEvents :: IORef Value
  , hSeqn :: IORef Double
  , hOpen :: IORef Double
  , hInTransition :: IORef Bool
  -- | WHICH callback is running, not merely that one is. §8.1 puts
  -- resource capture in @activate@ and §8.3 says @release@ outside
  -- @activate@ is @plugin_release_scope@ — and a boolean alone cannot
  -- tell @activate@ from @define@, so it admitted an acquire in
  -- @define@ whose scope @unload@ would never unwind.
  , hPhase :: IORef String
  }

data HostOptions = HostOptions
  { oCatalog :: Maybe Catalog
  , oReserved :: Value
  , oKeys :: Value
  , oDefaults :: Value
  , oProfile :: Value
  , oPoints :: Value
  , oBases :: [(String, Value -> IO Value)]
  , oDependency :: String
  }

noHostOptions :: HostOptions
noHostOptions =
  HostOptions Nothing VNull VNull VNull VNull VNull [] ""

data DeclareSpec = DeclareSpec
  { sDefinition :: String
  , sOptions :: Maybe Value
  , sOrder :: Value
  , sPos :: Maybe Double
  , sTag :: String
  -- | §9.1: set ONLY by @hostdeclare@ — "the host declares those
  -- instances itself, after the user merge, and always wins".
  , sHostOwned :: Bool
  }

noSpec :: DeclareSpec
noSpec = DeclareSpec "" Nothing VNull Nothing "" False
