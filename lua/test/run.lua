-- The whole suite: pure sections by direct call, driver sections by
-- command list, and a coverage guard above both.
--
-- A plain script rather than busted, for the same reason the port has no
-- rocks: a conformance suite whose only job is to run one corpus and
-- report which entries disagree does not need a framework, and adding one
-- would make `make test` depend on a rock tree nobody else in this repo
-- has.

local P = require 'plugin'
local T = P.types
local Corpus = require 'corpus'
local Driver = require 'driver'

local FAILURES = {}
local RAN = { sections = 0, entries = 0 }

local function report(name, group, i, entry, why)
  FAILURES[#FAILURES + 1] = name .. '/' .. Corpus.label(group, i, entry)
      .. ': ' .. why
end

-- Dispatch every group, and fail on a group the runner does not know - a
-- group silently not run is worse than a failure.
local function run_section(name, subject)
  RAN.sections = RAN.sections + 1
  for _, g in ipairs(Corpus.section(name)) do
    local fn = subject[g.group]
    if nil == fn then
      FAILURES[#FAILURES + 1] = name .. ': corpus group with no subject: '
          .. g.group
    else
      for i = 1, #g.set do
        RAN.entries = RAN.entries + 1
        local why = Corpus.check(g.set[i], fn)
        if nil ~= why then report(name, g.group, i, g.set[i], why) end
      end
    end
  end
end

-- ---- pure sections -------------------------------------------------

local parse = function(e) return P.parse_ref(T.getv(e, 'in')) end
local format = function(e)
  local args = T.getv(e, 'args') or T.list {}
  return P.format_ref(args[1], args[2])
end
local name = function(e) return P.check_name(T.getv(e, 'in')) end
local tag = function(e) return P.check_tag(T.getv(e, 'in')) end

run_section('ref', {
  parse = parse, parsebad = parse,
  format = format, formatbad = format,
  canon = function(e) return P.canon_ref(T.getv(e, 'in')) end,
  name = name, tag = tag, bound = name, boundtag = tag,
})

local env = function(e) return P.apply_env(T.getv(e, 'in')) end
run_section('env', {
  option = env, value = env, toggle = env,
  profile = env, ambiguous = env, reserved = env,
})

local rng = function(e) return P.parse_range(T.getv(e, 'in')) end
run_section('version', {
  range = rng, rangebad = rng,
  satisfies = function(e)
    local input = T.getv(e, 'in')
    return P.satisfies(T.getv(input, 'version'), T.getv(input, 'range'))
  end,
})

local cap = function(e)
  local input = T.getv(e, 'in')
  return P.resolve_capability(T.getv(input, 'req'), T.getv(input, 'candidates'))
end
run_section('capability', { match = cap, nested = cap, rank = cap })

local graph = function(e) return P.resolve_graph(T.getv(e, 'in')) end
run_section('graph', { resolve = graph, blocked = graph })

run_section('resolve', {
  candidates = function(e)
    local input = T.getv(e, 'in')
    return P.resolve_candidates(T.getv(input, 'name'), T.getv(input, 'sources'))
  end,
  from = function(e) return P.resolve_from(T.getv(e, 'in')) end,
})

-- `config` picks its subject by group PREFIX rather than by name, because
-- the two functions split the section cleanly.
RAN.sections = RAN.sections + 1
for _, g in ipairs(Corpus.section('config')) do
  local fn
  if 'norm' == g.group:sub(1, 4) then
    fn = function(e) return P.normalize_config(T.getv(e, 'in')) end
  elseif 'opt' == g.group:sub(1, 3) then
    fn = function(e) return P.resolve_options(T.getv(e, 'in')) end
  end
  if nil == fn then
    FAILURES[#FAILURES + 1] = 'config: corpus group with no subject: ' .. g.group
  else
    for i = 1, #g.set do
      RAN.entries = RAN.entries + 1
      local why = Corpus.check(g.set[i], fn)
      if nil ~= why then report('config', g.group, i, g.set[i], why) end
    end
  end
end

-- ---- driver sections -----------------------------------------------

local DRIVER_SECTIONS = {
  'lifecycle', 'order', 'point', 'export', 'depend',
  'declare', 'state', 'resource', 'nest', 'trace', 'apply', 'error',
}

local drive = function(e) return Driver.drive(T.getv(e, 'cmd')) end
for _, name2 in ipairs(DRIVER_SECTIONS) do
  RAN.sections = RAN.sections + 1
  for _, g in ipairs(Corpus.section(name2)) do
    for i = 1, #g.set do
      RAN.entries = RAN.entries + 1
      if not T.islist(T.getv(g.set[i], 'cmd')) then
        report(name2, g.group, i, g.set[i], 'driver entry without cmd')
      else
        local why = Corpus.check(g.set[i], drive)
        if nil ~= why then report(name2, g.group, i, g.set[i], why) end
      end
    end
  end
end

-- ---- coverage ------------------------------------------------------
--
-- EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
-- GROUP with no subject; this closes the level above, because a whole
-- SECTION the runner never mentions is a section silently not run.

local PURE_SECTIONS = { 'ref', 'env', 'version', 'capability', 'graph',
                        'resolve', 'config' }

local spec = Corpus.corpus()
local primary = T.getv(spec, 'primary') or T.map {}

-- The corpus metadata block is what turns on strict entry validation in
-- every runner, so a corpus that lost it must not silently downgrade this
-- port's checking.
if 1 ~= T.getv(T.getv(spec, 'PLUGIN') or T.map {}, 'version') then
  FAILURES[#FAILURES + 1] = 'corpus PLUGIN.version must be 1'
end

local ran = {}
for _, n in ipairs(PURE_SECTIONS) do ran[n] = true end
for _, n in ipairs(DRIVER_SECTIONS) do ran[n] = true end

local missing = {}
for _, n in ipairs(T.keys(primary)) do
  if not ran[n] then missing[#missing + 1] = n end
end
if 0 < #missing then
  FAILURES[#FAILURES + 1] = 'corpus sections no test runs: '
      .. table.concat(missing, ', ')
end

local extra = {}
for n in pairs(ran) do
  if not T.has(primary, n) then extra[#extra + 1] = n end
end
table.sort(extra)
if 0 < #extra then
  FAILURES[#FAILURES + 1] = 'tests name sections the corpus does not have: '
      .. table.concat(extra, ', ')
end

-- A floor, not a fixture: the corpus grows, and a run that suddenly covers
-- a fraction of it is the failure worth catching.
if RAN.entries < 400 then
  FAILURES[#FAILURES + 1] = 'only ' .. RAN.entries .. ' corpus entries reachable'
end

-- ---- report --------------------------------------------------------

if 0 == #FAILURES then
  print('lua: ' .. RAN.entries .. ' corpus entries across ' .. RAN.sections
        .. ' sections, all pass')
  os.exit(0)
end

for _, f in ipairs(FAILURES) do io.stderr:write(f .. '\n') end
io.stderr:write('\nlua: ' .. #FAILURES .. ' failure(s) of ' .. RAN.entries
                .. ' entries\n')
os.exit(1)
