-- | Errors, and the raise mechanism (§12).
--
-- EVERYTHING THAT CAN RAISE IS IN IO, AND THAT IS THE PORT'S ONE BIG
-- DECISION. Haskell can 'throw' from pure code, but the exception only
-- fires when the thunk is FORCED — and the corpus does not merely
-- assert that a call raises, it asserts WHAT SURVIVED a raise
-- mid-sequence (@resource\/unwind@, @lifecycle\/fail@). A raise that
-- happens whenever the consumer happens to look is a different
-- semantics from one that happens at the call, and laziness would let a
-- port pass the "does it raise" entries while getting every ordering
-- entry wrong for reasons no reader could see.
--
-- So the split here is not pure/impure by taste: a function is 'IO'
-- exactly when it can raise. 'checkname' is pure because it answers
-- 'Bool'; 'parseRef' is 'IO' because it raises.
--
-- Ports compare by CODE and never by message: wording is a port's own
-- business. The FORMAT is pinned, because a parseable message is what
-- makes a log searchable across twenty languages.

module Types
  ( PluginError(..)
  , raise, formatError
  , details1, details2
  , mergeValue, matchValue
  ) where

import Control.Exception (Exception, throwIO)
import Value

data PluginError = PluginError
  { peCode :: String
  , peText :: String
  , peDetails :: Value
  , peMessage :: String
  }

instance Show PluginError where
  show = peMessage

instance Exception PluginError

-- | §12's detail fields, IN THIS FIXED ORDER. The order is part of the
-- contract: an earlier draft named six fields while other sections
-- promised diagnostics with nowhere to go, which would have left each
-- port inventing its own order and breaking message parity.
detailOrder :: [String]
detailOrder =
  [ "host", "ref", "name", "tag", "point", "key", "capability"
  , "range", "version", "match", "candidates", "cycle", "holders"
  , "refs", "path", "cause" ]

-- | Values render as COMPACT JSON, so a value containing a space or a
-- bracket cannot break the parse and a list renders as an array. The
-- bracket is absent entirely when no field applies.
formatError :: String -> String -> Value -> String
formatError code text details =
  case parts of
    [] -> headline
    _ -> headline ++ " [" ++ unwords parts ++ "]"
  where
    headline = "plugin/" ++ code ++ ": " ++ text
    parts =
      [ k ++ "=" ++ renderJson (vget details k)
      | k <- detailOrder, vhas details k ]

raise :: String -> String -> Value -> IO a
raise code text details =
  throwIO (PluginError code text details (formatError code text details))

details1 :: String -> Value -> Value
details1 k v = vset (VMap []) k v

details2 :: String -> Value -> String -> Value -> Value
details2 k1 v1 k2 v2 = vset (vset (VMap []) k1 v1) k2 v2

-- | Deep merge, struct's semantics: maps merge, everything else
-- replaces. §16 permits voxgig/struct for this and Haskell has no port
-- of it.
mergeValue :: Value -> Value -> Value
mergeValue a b
  | not (isMap a && isMap b) = b
  | otherwise = foldl step a (vkeys b)
  where
    step acc k =
      let bv = vget b k
          av = vget acc k
      in vset acc k (if isMap av && isMap bv then mergeValue av bv else bv)

-- | §11.1's partial match: every leaf in @want@ must be present and
-- equal in @have@; keys not mentioned are not checked.
matchValue :: Value -> Value -> Bool
matchValue want have
  | isNull want = True
  | isMap want =
      isMap have
        && all (\k -> vhas have k && matchValue (vget want k) (vget have k)) (vkeys want)
  | otherwise = same want have
