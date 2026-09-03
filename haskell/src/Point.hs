-- | Extension points (§6). Three kinds, chosen because they are what
-- the two existing systems actually needed, and no more.
--
-- A PLUGIN NEVER MUTATES THE HOST. That inversion is what makes
-- deactivation possible: sdkgen's @utility.fetcher = wrapped@ is not
-- undoable, but "this instance holds slot 3 of the request chain" is
-- undoable in O(1). OSGi named it the whiteboard pattern in 2004, in a
-- paper called /Listeners Considered Harmful/, and for exactly this
-- reason.
--
-- A CLOSURE IS A CLOSURE, which is the whole difference from the `c`
-- port: a chain binding receives its @next@ as a function the
-- composition built — the same shape the canonical writes — instead of
-- c's explicit @Chain *@ walked by index.

module Point
  ( Bound(..), Hook, Next, ChainFn
  , pointCall, pointEmit, pointProvider, callHook
  ) where

import Control.Exception (catch)
import Data.List (sort, sortBy)
import Types
import Value

-- | A binding answers with a 'Maybe': 'Nothing' DECLINES, @Just v@
-- answers. @bail@ needs the distinction and `c` reaches it with a NULL
-- pointer; here it is the type.
type Hook = Value -> IO (Maybe Value)

-- | The remaining composition, as seen by one chain binding. A binding
-- may CALL it and must not store it — a plugin that stashes @next@ and
-- calls it after deactivation is a bug the host cannot prevent, and
-- saying so is better than pretending otherwise (§6.2).
type Next = Value -> IO Value

type ChainFn = Next -> Value -> IO Value

data Bound = Bound
  { bRef :: String
  , bPoint :: String
  -- | @provider@ ranks by HIGHEST band, unlike hook and chain which run
  -- lowest first. Kept as declared so the two rules stay visibly
  -- different rather than one being derived from the other by a reader
  -- who then gets it backwards.
  , bBand :: Double
  , bHook :: Maybe Hook
  , bChain :: Maybe ChainFn
  }

callHook :: Bound -> Value -> IO (Maybe Value)
callHook b arg = maybe (return Nothing) ($ arg) (bHook b)

-- | Composition: @b1(b2(b3(base)))@, FIRST BINDING OUTERMOST (§6.2).
pointCall :: [Bound] -> Maybe (Value -> IO Value) -> Value -> IO Value
pointCall bindings base = go bindings
  where
    go [] a = maybe (return a) ($ a) base
    go (b : rest) a = maybe (go rest a) (\c -> c (go rest) a) (bChain b)

-- | Fan-out. Return values are ignored except in @bail@.
--
-- §6.1: "fan-out" is not one answer but four. In a language with
-- asynchrony, "call every binding" hides a decision — start them all
-- and wait, await each in turn, or do not wait — and a design that
-- leaves it unsaid gets four different answers from four ports, in the
-- concurrency behaviour of production code no corpus entry happens to
-- cover. This port is synchronous, so all four modes are sequential
-- here and only the ERROR and RETURN handling distinguishes them.
--
-- Answers @(result, errors)@.
pointEmit :: [Bound] -> String -> Value -> IO (Maybe Value, Value)
pointEmit bindings mode arg
  -- Stops at the first binding that RETURNS A VALUE — the "handled,
  -- stop" case. 'Nothing', AND A JSON NULL, BOTH DECLINE.
  --
  -- JavaScript can tell null from undefined and almost nothing else in
  -- the target set can — Go, Python, Ruby, PHP, Lua, Java and C# each
  -- have exactly one way to say nothing. Making the distinction
  -- load-bearing would cost every one of them a wrapper type carried
  -- through the whole dispatch path, to express a difference their
  -- plugin authors cannot write. §18's budget settles it (§6.1).
  | mode == "bail" = do
      r <- bail bindings
      return (r, VList [])
  | otherwise = do
      errs <- foldl step (return []) bindings
      return (Nothing, VList (reverse errs))
  where
    bail [] = return Nothing
    bail (b : rest) = do
      v <- callHook b arg
      case v of
        Just x | not (isNull x) -> return (Just x)
        _ -> bail rest

    raising = mode == "emit"
    step acc b = do
      es <- acc
      -- @emit@ raises synchronously; the collecting modes gather.
      if raising
        then do _ <- callHook b arg; return es
        else
          (do _ <- callHook b arg; return es)
            `catch` \e ->
              return
                ( vset (vset (VMap []) "code" (VStr (peCode e))) "message" (VStr (peMessage e))
                    : es )

-- | At most one live implementation (§6.3). The winner is the highest
-- band, ties broken by ref sort, and THE LOSERS ARE VISIBLE rather than
-- silently ignored. Answers @(winner, shadowed refs)@.
pointProvider :: [Bound] -> Bool -> IO (Maybe Bound, Value)
pointProvider [] _ = return (Nothing, VList [])
pointProvider bindings exclusive
  | exclusive && length bindings > 1 =
      -- Sorted, so the message names the same pair whatever order the
      -- bindings arrived in.
      raise "plugin_point_exclusive"
        ("point is exclusive and has " ++ show (length bindings) ++ " bindings: " ++ commas refs)
        (details1 "refs" (VList (map VStr refs)))
  | otherwise = return (Just (head ranked), VList (map (VStr . bRef) (tail ranked)))
  where
    refs = sort (map bRef bindings)
    -- HIGHEST band wins, unlike hook and chain; ties break by ref sort,
    -- which is a TOTAL order.
    ranked = sortBy (\a b -> compare (negate (bBand a), bRef a) (negate (bBand b), bRef b)) bindings

commas :: [String] -> String
commas [] = ""
commas [x] = x
commas (x : xs) = x ++ ", " ++ commas xs
