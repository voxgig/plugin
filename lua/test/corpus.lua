-- The corpus runner.
--
-- Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
-- exactly as every other port's runner does. No port needs a Node
-- toolchain to run its tests, and this one does not get a private door
-- into the source either.
--
-- A group name selects the subject. That is the whole dispatch, and it is
-- deliberately dumb: a runner that inferred the subject from the entry's
-- shape would silently run the wrong function when an entry was mistyped.

local P = require 'plugin'
local T = P.types
local J = P.json

local M = {}

M.SPEC = 'spec/plugin.json'

-- A sentinel for "this key was not present". A lua table cannot store a
-- nil, so the parser turns a JSON null into `T.NULL` and absence stays
-- absence - and `__UNDEF__` and `__NULL__` are different assertions.
M.MISSING = setmetatable({}, { __tostring = function() return 'MISSING' end })

-- THE ORACLE'S OWN CONTAINER TEST, not the library's.
--
-- AGENTS.md section 1: "The plugin library must never be used to implement
-- its own tests." That covers the TYPING as well as the comparison. A
-- table in lua is both a map and a list, so this port stamps a metatable
-- on every table it builds and `T.ismap`/`T.islist`/`T.keys` read it -
-- which makes them exactly the behaviour the corpus's map-versus-list
-- entries exist to check. An oracle calling them would misclassify in
-- lockstep with a broken port and stay green.
--
-- So the oracle reads the TAG rather than asking the library about it:
-- `__jsontype` is the mark the port stamped, the way `JSON::PP::Boolean`
-- is a mark the perl runner reads. `rawget` because a metatable of a
-- metatable must not answer for it.
local function tagof(v)
  if 'table' ~= type(v) then return nil end
  local mt = getmetatable(v)
  if nil == mt then return nil end
  return rawget(mt, '__jsontype')
end

local function ismap(v) return 'map' == tagof(v) end
local function islist(v) return 'list' == tagof(v) end

-- The oracle's own key walk. `pairs` has no defined order, so this sorts -
-- but it enumerates for itself, so a `T.keys` that dropped a key or
-- returned it unsorted no longer moves the oracle with it.
local function keysof(t)
  local out = {}
  if not ismap(t) then return out end
  for k in pairs(t) do out[#out + 1] = k end
  table.sort(out)
  return out
end

-- Presence, read off the table rather than through `T.has`.
local function haskey(t, k)
  return ismap(t) and nil ~= rawget(t, k)
end

-- The oracle's own map constructor, stamping the tag `ismap` above reads.
-- Building with `T.map` would have let a mutation that stopped stamping
-- take the oracle's own scaffolding with it.
local ORACLE_MAP_MT = { __jsontype = 'map' }

local function mapof(t)
  return setmetatable(t or {}, ORACLE_MAP_MT)
end

-- The value at a key, with the port's present-null sentinel flattened to
-- nil. `T.NULL` is a VALUE the port produces, like `JSON::PP::Boolean` in
-- perl - reading it is not the same as borrowing a comparison.
local function valueat(t, k)
  if not ismap(t) then return nil end
  local v = rawget(t, k)
  if T.NULL == v then return nil end
  return v
end

local cache

function M.corpus()
  if nil == cache then
    -- Relative to the port directory, which is where `make test` runs.
    local file = assert(io.open('../' .. M.SPEC, 'r'),
                        'cannot read ../' .. M.SPEC)
    local text = file:read('a')
    file:close()
    cache = J.parse(text)
  end
  return cache
end

-- The groups of a section, minus `DEF`, in name order.
function M.section(name)
  local primary = valueat(M.corpus(), 'primary')
  local sec = primary and valueat(primary, name) or nil
  if nil == sec then
    error('no such corpus section: ' .. name, 0)
  end
  local out = {}
  for _, group in ipairs(keysof(sec)) do
    if 'DEF' ~= group then
      local set = valueat(sec[group], 'set')
      if islist(set) then
        out[#out + 1] = { group = group, set = set }
      end
    end
  end
  return out
end

-- A stable label, so a failure names the entry rather than an index.
function M.label(group, i, entry)
  return valueat(entry, 'id') or (group .. '#' .. i)
end

-- A LITERAL-WITH-ANCHORS MATCHER, NOT A REGEX ENGINE.
--
-- Lua has patterns rather than regexes and they are not the same language:
-- `%` escapes, no alternation, and a different meaning for `-`. Every
-- pattern the corpus writes is a literal, optionally `^`-anchored, so this
-- unescapes and compares - and ERRORS on any unescaped metacharacter,
-- because the one thing a hand-rolled matcher must never do is quietly
-- report a mismatch it could not evaluate.
function M.regexlite(pattern, text)
  local literal = {}
  local anchorstart = false
  local anchorend = false
  local i = 1
  while i <= #pattern do
    local c = pattern:sub(i, i)
    if '\\' == c then
      literal[#literal + 1] = pattern:sub(i + 1, i + 1)
      i = i + 2
    elseif '^' == c and 1 == i then
      anchorstart = true
      i = i + 1
    elseif '$' == c and i == #pattern then
      anchorend = true
      i = i + 1
    else
      if nil ~= ('*+?()[]{}|.'):find(c, 1, true) then
        error('corpus regex needs a real engine, which this port does not '
              .. 'have: ' .. pattern, 0)
      end
      literal[#literal + 1] = c
      i = i + 1
    end
  end
  local lit = table.concat(literal)

  if anchorstart and anchorend then return text == lit end
  if anchorstart then return lit == text:sub(1, #lit) end
  if anchorend then return lit == text:sub(#text - #lit + 1) end
  return nil ~= text:find(lit, 1, true)
end

-- Deep equality over spec values. Key order never matters; list order
-- always does.
function M.same(a, b)
  if ismap(a) or ismap(b) then
    if not (ismap(a) and ismap(b)) then return false end
    local ka, kb = keysof(a), keysof(b)
    if #ka ~= #kb then return false end
    for i = 1, #ka do
      if ka[i] ~= kb[i] then return false end
      if not M.same(a[ka[i]], b[ka[i]]) then return false end
    end
    return true
  end
  if islist(a) or islist(b) then
    if not (islist(a) and islist(b)) then return false end
    if #a ~= #b then return false end
    for i = 1, #a do
      if not M.same(a[i], b[i]) then return false end
    end
    return true
  end
  return a == b
end

-- Partial match: every key the expectation names must agree, and keys it
-- does not name are ignored. `__EXISTS__` asserts presence without pinning
-- a value; `/re/` matches a string as a regular expression.
function M.matches(expect, actual)
  if '__EXISTS__' == expect then
    return M.MISSING ~= actual and nil ~= actual and T.NULL ~= actual
  end
  if '__UNDEF__' == expect then
    return M.MISSING == actual
  end
  if '__NULL__' == expect then
    return M.MISSING ~= actual and T.NULL == actual
  end

  local got = actual
  if M.MISSING == got then got = T.NULL end

  if 'string' == type(expect) and 2 < #expect
      and '/' == expect:sub(1, 1) and '/' == expect:sub(-1) then
    if 'string' ~= type(got) then return false end
    return M.regexlite(expect:sub(2, -2), got)
  end

  if islist(expect) then
    if not islist(got) or #expect ~= #got then return false end
    for i = 1, #expect do
      if not M.matches(expect[i], got[i]) then return false end
    end
    return true
  end

  if ismap(expect) then
    if not ismap(got) then return false end
    for _, k in ipairs(keysof(expect)) do
      -- NOT `haskey(got, k) and got[k] or M.MISSING`. Lua's `and`/`or` is
      -- not a ternary when the middle term can be FALSE: a present `false`
      -- would fall through to MISSING and read as absent, which failed ten
      -- entries whose only crime was a `false` in the expectation.
      local sub = M.MISSING
      if haskey(got, k) then sub = got[k] end
      if not M.matches(expect[k], sub) then return false end
    end
    return true
  end

  return M.same(expect, got)
end

-- Run one entry against a subject and report the disagreement, if any.
--
-- The three combinations the spec format allows are enforced here as well
-- as at build time, because a runner that quietly accepted `err` beside
-- `out` would let a contradictory entry pass.
function M.check(entry, subject)
  if haskey(entry, 'err') and haskey(entry, 'out') then
    return 'entry has both err and out'
  end

  local ok, value = pcall(subject, entry)

  if haskey(entry, 'err') then
    if ok then
      return 'expected a raise, got: ' .. T.encode(value)
    end
    local want = entry.err
    if true ~= want then
      -- Errors compare by CODE (section 12). Message wording is a port's
      -- own business, and pinning it would make every translation a corpus
      -- change.
      local got = T.codeof(value)
      if got ~= want then
        return 'expected code ' .. tostring(want) .. ', got ' .. got
               .. ' (' .. T.message(value) .. ')'
      end
    end
    if haskey(entry, 'match') then
      local got = mapof {
        err = mapof {
          code = T.codeof(value),
          message = T.message(value),
          name = 'PluginError',
        },
      }
      if not M.matches(entry.match, got) then
        return 'error did not match ' .. T.encode(entry.match)
               .. ', got ' .. T.encode(got)
      end
    end
    return nil
  end

  if not ok then
    return 'unexpected raise: ' .. T.codeof(value) .. ' ' .. T.message(value)
  end

  if haskey(entry, 'out') and not M.same(entry.out, value) then
    return 'expected ' .. T.encode(entry.out) .. ', got ' .. T.encode(value)
  end

  if haskey(entry, 'match') then
    local got = mapof { ['in'] = valueat(entry, 'in'), out = value }
    if not M.matches(entry.match, got) then
      return 'did not match ' .. T.encode(entry.match)
             .. ', got out=' .. T.encode(value)
    end
  end

  if not haskey(entry, 'out') and not haskey(entry, 'match') then
    return 'entry asserts nothing'
  end

  return nil
end

return M
