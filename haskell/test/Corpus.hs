-- | The corpus reader and the entry check (DOCS.md §4.5, §15).
--
-- THE PLUGIN LIBRARY MUST NEVER BE USED TO IMPLEMENT ITS OWN TESTS
-- (AGENTS.md prime directive 6), and that covers the TYPING as well as
-- the comparison. This file asks "Value" what a value is, because
-- "Value" is the JSON reader rather than the library under test — but
-- @same@, @truthy@ and the merge semantics the corpus pins are all
-- re-derived here rather than borrowed from "Types".
--
-- NO TEST FRAMEWORK: §16 permits one runtime dependency, Haskell has no
-- port of it, and HUnit or hspec would be a second. The runner is a
-- @main@ that counts. THE CORPUS IS A VALUE THREADED THROUGH, not a
-- top-level 'IORef': a global would need @unsafePerformIO@ and a
-- NOINLINE pragma to be even approximately correct, which is a lot of
-- machinery for "read a file once".

module Corpus
  ( Subject, Tally(..)
  , loadCorpus, corpusSection, corpusLabel
  , corpusEqual, corpusMatches, regexLite
  , runSection
  ) where

import Control.Exception (try)
import Control.Monad (forM_, when)
import Data.IORef
import Data.List (isPrefixOf, sort)
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
import Types
import Value

type Subject = Value -> IO Value

data Tally = Tally {tEntries :: Int, tFailures :: Int}

die :: String -> IO a
die msg = hPutStrLn stderr msg >> exitWith (ExitFailure 2)

-- | The whole corpus, parsed once. Exits loudly if the JSON is missing
-- or malformed: a runner that reports zero tests as a pass is the
-- failure mode doc/plan/handover.md §4 exists to prevent.
loadCorpus :: IO Value
loadCorpus = do
  env <- lookupEnv "PLUGIN_SPEC"
  let path = case env of Just p | not (null p) -> p; _ -> "../spec/plugin.json"
  text <- readFile path
  v <- either (\e -> die ("haskell: " ++ path ++ " is not valid JSON: " ++ e)) return (parseJson text)
  -- Version 1 turns on strict entry validation in every runner. A
  -- corpus that lost its version marker is a corpus whose shape nobody
  -- checked, so refuse it rather than run against it.
  let version = vget (vget v "PLUGIN") "version"
  when (not (isNum version) || asNum version /= 1) $ die "haskell: unsupported spec version"
  return v

corpusSection :: Value -> String -> IO Value
corpusSection cor name = do
  let s = vget (vget cor "primary") name
  when (not (isMap s)) $ die ("haskell: no such corpus section: " ++ name)
  return s

-- | A stable label, so a failure names the entry rather than an index.
corpusLabel :: String -> Int -> Value -> String
corpusLabel group i entry =
  let idv = vget entry "id"
  in if isStr idv then asStr idv else group ++ "#" ++ show i

-- | Deep equality over spec values: key order never matters, list order
-- always does. Written here, not taken from the library.
corpusEqual :: Value -> Value -> Bool
corpusEqual VNull VNull = True
corpusEqual (VBool a) (VBool b) = a == b
corpusEqual (VNum a) (VNum b) = a == b
corpusEqual (VStr a) (VStr b) = a == b
corpusEqual (VList a) (VList b) = length a == length b && and (zipWith corpusEqual a b)
corpusEqual a@(VMap x) b@(VMap y) =
  length x == length y && all (\k -> vhas b k && corpusEqual (vget a k) (vget b k)) (vkeys a)
corpusEqual _ _ = False

-- | A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.
--
-- GHC's boot libraries carry no regex engine, and §16 permits no second
-- dependency to supply one. Every pattern the corpus writes is a
-- literal, optionally @^@-anchored, so this unescapes and compares —
-- and ERRORS on any unescaped metacharacter, because the one thing a
-- hand-rolled matcher must never do is quietly report a mismatch it
-- could not evaluate.
--
-- Same shape as @lua\/test\/corpus.lua@'s @regexlite@, deliberately.
regexLite :: String -> String -> Bool
regexLite pattern text = go pattern "" False
  where
    go [] acc anchorStart =
      let lit = reverse acc
      in if anchorStart then lit `isPrefixOf` text else lit `infixOf` text
    go ('\\' : c : rest) acc a = go rest (c : acc) a
    go ('^' : rest) acc _
      | null acc && length rest == length pattern - 1 = go rest acc True
    go ('$' : []) acc a =
      let lit = reverse acc
      in if a then text == lit else lit `suffixOf` text
    go (c : rest) acc a
      | c `elem` "*+?()[]{}|." =
          error ("corpus regex needs a real engine, which this port does not have: " ++ pattern)
      | otherwise = go rest (c : acc) a

    infixOf needle hay = any (needle `isPrefixOf`) (tails' hay)
    suffixOf needle hay = reverse needle `isPrefixOf` reverse hay
    tails' [] = [[]]
    tails' s@(_ : xs) = s : tails' xs

-- | @match@ semantics: @__EXISTS__@, @__UNDEF__@, @__NULL__@,
-- @\/regex\/@, and partial map matching. @present@ distinguishes an
-- absent key from one holding null, which @__UNDEF__@ and @__NULL__@
-- exist to tell apart.
corpusMatches :: Value -> Value -> Bool -> Bool
corpusMatches expect actual present
  | isStr expect =
      case asStr expect of
        "__EXISTS__" -> present && not (isNull actual)
        "__UNDEF__" -> not present
        "__NULL__" -> present && isNull actual
        s
          | length s > 2 && head s == '/' && last s == '/' ->
              isStr actual && regexLite (init (tail s)) (asStr actual)
          | otherwise -> structural
  | otherwise = structural
  where
    structural
      | isList expect =
          isList actual && vlen expect == vlen actual
            && and (zipWith (\e a -> corpusMatches e a True) (vitems expect) (vitems actual))
      | isMap expect =
          isMap actual
            && all (\k -> corpusMatches (vget expect k) (vget actual k) (vhas actual k))
                 (sort (vkeys expect))
      | otherwise = corpusEqual expect actual

-- | Run one entry and report the disagreement, or 'Nothing' when it
-- passes.
--
-- The three combinations the spec format allows are enforced here as
-- well as at build time, because a runner that quietly accepted @err@
-- beside @out@ would let a contradictory entry pass.
corpusCheck :: Value -> Subject -> IO (Maybe String)
corpusCheck entry subject
  | haserr && hasout = return (Just "entry has both err and out")
  | not haserr && not hasout && not hasmatch = return (Just "entry asserts nothing")
  | otherwise = do
      outcome <- try (subject entry)
      case outcome of
        Left e -> return (onRaise (e :: PluginError))
        Right value -> return (onValue value)
  where
    haserr = vhas entry "err"
    hasout = vhas entry "out"
    hasmatch = vhas entry "match"

    onRaise e
      | not haserr = Just ("unexpected raise: " ++ peCode e ++ " " ++ peMessage e)
      -- Errors compare by CODE (§12). Message wording is a port's own
      -- business; pinning it would make every translation a corpus
      -- change.
      | isStr want && peCode e /= asStr want =
          Just ("expected code " ++ asStr want ++ ", got " ++ peCode e ++ " (" ++ peMessage e ++ ")")
      | hasmatch && not (corpusMatches (vget entry "match") got True) =
          Just ("error did not match " ++ renderJson (vget entry "match") ++ ", got " ++ renderJson got)
      | otherwise = Nothing
      where
        want = vget entry "err"
        errv =
          vset (vset (vset (VMap []) "code" (VStr (peCode e))) "message" (VStr (peMessage e)))
            "name" (VStr "PluginError")
        got = vset (VMap []) "err" errv

    onValue value
      | haserr = Just ("expected a raise, got: " ++ renderJson value)
      | hasout && not (corpusEqual (vget entry "out") value) =
          Just ("expected " ++ renderJson (vget entry "out") ++ ", got " ++ renderJson value)
      | hasmatch && not (corpusMatches (vget entry "match") got True) =
          Just ("did not match " ++ renderJson (vget entry "match") ++ ", got out=" ++ renderJson value)
      | otherwise = Nothing
      where
        got = vset (vset (VMap []) "in" (vget entry "in")) "out" value

runSection :: Value -> IORef Tally -> String -> (String -> Maybe Subject) -> IO ()
runSection cor tally sec lookupSubject = do
  groups <- corpusSection cor sec
  -- SORTED, so a failure names the same group in the same place on
  -- every run.
  forM_ (sort (vkeys groups)) $ \name ->
    case lookupSubject name of
      -- A group the runner does not know is a group silently not run,
      -- which is worse than a failure.
      Nothing -> do
        modifyIORef' tally (\t -> t {tFailures = tFailures t + 1})
        putStrLn (sec ++ "/" ++ name ++ ": no subject for this group")
      Just s -> runGroup tally sec name (vget groups name) s

runGroup :: IORef Tally -> String -> String -> Value -> Subject -> IO ()
runGroup tally sec group entries subject = do
  let set = vget entries "set"
  when (isList set) $
    forM_ (zip [0 ..] (vitems set)) $ \(i, entry) -> do
      modifyIORef' tally (\t -> t {tEntries = tEntries t + 1})
      why <- corpusCheck entry subject
      case why of
        Nothing -> return ()
        Just msg -> do
          modifyIORef' tally (\t -> t {tFailures = tFailures t + 1})
          -- The label is the entry's own @id@ when it has one, and
          -- those already carry the section — printing the section
          -- again would read @ref\/ref\/canon#trailing@.
          let l = corpusLabel group i entry
          putStrLn (if vhas entry "id" then l ++ ": " ++ msg else sec ++ "/" ++ l ++ ": " ++ msg)
