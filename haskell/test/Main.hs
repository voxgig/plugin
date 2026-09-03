-- | The haskell port's test runner.
--
-- NO TEST FRAMEWORK (§16): a @main@ that counts. It reports the entry
-- count as well as the pass, because "all pass" over zero entries is
-- the failure doc/plan/handover.md §4 warns about.

module Main (main) where

import Capability (resolveCapability)
import Config (normalizeConfig, resolveOptions)
import Corpus
import Data.IORef
import Data.List (isPrefixOf)
import Driver (drive)
import Env (applyEnv)
import Graph (resolveGraph)
import Ref
import Resolve (resolveCandidates, resolveFrom)
import System.Exit (ExitCode (..), exitWith)
import Value
import Version (parseRange, satisfies)

-- | §15.3's @ref@ section, group by group. EVERY group must have a
-- subject: a group the runner does not know is a group silently not
-- run, which is worse than a failure.
refSubject :: String -> Maybe Subject
refSubject g = case g of
  _ | g `elem` ["name", "bound"] -> Just (\e -> return (VBool (checkname (vget e "in"))))
    | g `elem` ["tag", "boundtag"] -> Just (\e -> return (VBool (checktag (vget e "in"))))
    | g `elem` ["parse", "parsebad"] -> Just (\e -> parseRef (vget e "in"))
    | g `elem` ["format", "formatbad"] ->
        Just (\e -> let args = vget e "args" in VStr <$> formatRef (vat args 0) (vat args 1))
    | g == "canon" -> Just (\e -> VStr <$> canonRef (vget e "in"))
    | otherwise -> Nothing

-- --- version: the range grammar and the one predicate ------------------

versionSubject :: String -> Maybe Subject
versionSubject g
  | g `elem` ["range", "rangebad"] = Just (\e -> parseRange (vget e "in"))
  | g == "satisfies" =
      Just (\e -> let i = vget e "in" in VBool <$> satisfies (vget i "version") (vget i "range"))
  | otherwise = Nothing

-- --- capability: matching and the total rank ---------------------------

capabilitySubject :: String -> Maybe Subject
capabilitySubject g
  | g `elem` ["match", "nested", "rank"] =
      Just (\e -> let i = vget e "in" in resolveCapability (vget i "req") (vget i "candidates"))
  | otherwise = Nothing

-- --- resolve: name to candidate module ids -----------------------------

resolveSubject :: String -> Maybe Subject
resolveSubject "candidates" =
  Just (\e -> let i = vget e "in" in return (resolveCandidates (vget i "name") (vget i "sources")))
resolveSubject "from" = Just (\e -> return (resolveFrom (vget e "in")))
resolveSubject _ = Nothing

-- --- env: the lossy encoding, and its collision ------------------------

-- | Every group in @env@ is one call: the section is a single pure
-- function over the whole input.
envSubject :: String -> Maybe Subject
envSubject _ = Just (\e -> applyEnv (vget e "in"))

-- --- config: normalization and the ten-level ladder --------------------

-- | The prefix IS the dispatch: @norm*@ groups normalize, @opt*@ groups
-- resolve. A group with neither prefix gets no subject and fails
-- loudly, rather than being silently skipped.
configSubject :: String -> Maybe Subject
configSubject g
  | "norm" `isPrefixOf` g = Just (\e -> normalizeConfig (vget e "in"))
  | "opt" `isPrefixOf` g = Just (\e -> resolveOptions (vget e "in"))
  | otherwise = Nothing

-- --- graph: resolved/blocked, and the explanation ----------------------

graphSubject :: String -> Maybe Subject
graphSubject g
  | g `elem` ["resolve", "blocked"] = Just (\e -> resolveGraph (vget e "in"))
  | otherwise = Nothing

-- --- the twelve DRIVER sections ----------------------------------------

-- | Every entry carries @cmd@, and a port needs DOCS.md §4 to run them
-- — the probe catalog, the command vocabulary, and the canonical
-- observable @{status, open, log, result}@. Corpus files alone are not
-- enough, which is why C2 shipped both together.
driverSubject :: String -> Maybe Subject
driverSubject _ = Just (\e -> drive (vget e "cmd"))

main :: IO ()
main = do
  cor <- loadCorpus
  tally <- newIORef (Tally 0 0)

  runSection cor tally "ref" refSubject
  runSection cor tally "version" versionSubject
  runSection cor tally "capability" capabilitySubject
  runSection cor tally "resolve" resolveSubject
  runSection cor tally "env" envSubject
  runSection cor tally "config" configSubject
  runSection cor tally "graph" graphSubject

  -- The driver sections, in §15.3's order. Each entry is a command list
  -- against a fresh host.
  mapM_
    (\s -> runSection cor tally s driverSubject)
    [ "lifecycle", "order", "point", "export", "depend", "declare"
    , "state", "resource", "nest", "trace", "apply", "error" ]

  t <- readIORef tally
  if tEntries t == 0
    then putStrLn "haskell: no corpus entries ran" >> exitWith (ExitFailure 1)
    else
      if tFailures t > 0
        then do
          putStrLn ("\nhaskell: " ++ show (tFailures t) ++ " failure(s) of " ++ show (tEntries t) ++ " entries")
          exitWith (ExitFailure 1)
        else putStrLn ("haskell: " ++ show (tEntries t) ++ " corpus entries, all pass")
