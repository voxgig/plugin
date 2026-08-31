-- The driver (DOCS.md section 4).
--
-- Every port implements this same small thing and nothing else is
-- port-specific: the probe catalog, the command interpreter, and the
-- canonical observable.

local P = require 'plugin'
local T = P.types

local M = {}

-- A sentinel for "this command produced nothing", so a command that
-- legitimately produces nil - `export` of a missing key - still overwrites
-- the previous result.
M.NOTHING = setmetatable({}, { __tostring = function() return 'NOTHING' end })

-- A value rendered as text: a string is itself, anything else is its JSON.
local function text(value)
  if 'string' == type(value) then return value end
  return T.encode(value)
end

local function num(value)
  if 'number' == type(value) then return value end
  return 0
end

local function declareprovides(inst)
  local provides = T.getv(inst:options(), 'provides')
  for i = 1, T.len(provides) do
    inst:provides(provides[i])
  end
end

local function boom(inst, callback)
  local opts = inst:options()
  if callback ~= T.getv(opts, 'fail') then return end

  -- `bare` raises WITHOUT a code - the ordinary library error section 12's
  -- `plugin_<phase>_failed` codes exist to wrap.
  if T.truthy(T.getv(opts, 'bare')) then
    error('probe failed at ' .. callback, 0)
  end

  T.fail(T.getv(opts, 'code') or ('plugin_' .. callback .. '_failed'),
         'probe failed at ' .. callback, nil)
end

local function reenter(inst, callback)
  if callback ~= T.getv(inst:options(), 'reenter') then return end
  -- A transition from inside a lifecycle callback (section 5.2).
  inst.host:activate(inst.ref)
end

-- The points every driver host declares. DOCS.md section 4.3 defines
-- `probe` as binding one hook point (`p`) and wrapping one chain point
-- (`c`), so a host without them cannot load the probe at all - they are
-- part of the contract's baseline rather than a fixture convenience. `v`
-- is the provider point the `provider` probe defaults to.
function M.withpoints(extra)
  local out = T.map {
    p = T.map { kind = 'hook' },
    c = T.map { kind = 'chain', base = function(v) return v end },
    v = T.map { kind = 'provider' },
  }
  -- A `host` command REPLACES a base point rather than merging into it, so
  -- an entry can redeclare `c` with its own base or `v` as exclusive
  -- without inheriting the default's shape.
  for _, k in ipairs(T.keys(extra)) do
    out[k] = extra[k]
  end
  return out
end

-- Section 4.3's six probes. Their behaviour is as much the contract as the
-- runner is - this is where twenty implementations of `noisy` are made to
-- fail at the same callback in the same way.
function M.probes()
  local out = {}

  local function record(name)
    return {
      name = name,
      define = function(i)
        if not T.has(i:state(), 'count') then i:state().count = 0 end
      end,
      activate = function(i) i:acquire() end,
    }
  end

  out[#out + 1] = {
    name = 'probe',
    define = function(i)
      if not T.has(i:state(), 'count') then i:state().count = 0 end
      local band = T.getv(i:options(), 'band')
      -- One hook binding (`p`) and one chain wrap (`c`) - the workhorse
      -- shape DOCS.md section 4.3 specifies.
      i:bind('p', function()
        i:state().count = num(T.getv(i:state(), 'count')) + 1
      end, band)
      -- Wrap AFTER next, so the result spells the nesting left to right:
      -- outermost first. Wrapping the ARGUMENT instead would spell it
      -- backwards and make every chain expectation read wrong.
      i:bind('c', function(nxt, v)
        local wrap = T.getv(i:options(), 'wrap') or ':'
        return wrap .. text(nxt(v))
      end, band)
      i:export('client', i.ref)
      -- The instance api itself, so the driver's `stray` command can call
      -- `release` from OUTSIDE a lifecycle callback.
      i:export('inst', i)
      declareprovides(i)
    end,
    activate = function(i)
      i:acquire()
      -- Section 6.5: an instance that is itself a host. The outer owns the
      -- inner's lifetime - registered in the scope, so it closes on
      -- deactivate in the same reverse unwind as every other resource.
      local nest = T.getv(i:options(), 'nest')
      if nil == nest then return end

      local inner = i:nest(T.map { points = M.withpoints(nil) })
      for _, d in ipairs(M.probes()) do inner:define(d) end
      for k = 1, T.len(nest) do inner:ready(nest[k]) end
    end,
  }

  out[#out + 1] = {
    name = 'noisy',
    define = function(i)
      if not T.has(i:state(), 'count') then i:state().count = 0 end
      boom(i, 'define')
    end,
    activate = function(i)
      -- Acquire BEFORE the raise, so a failing activate has something to
      -- leak if the scope does not unwind - which is the whole point of
      -- the entry that asserts open == 0 afterwards.
      i:acquire()
      reenter(i, 'activate')
      boom(i, 'activate')
    end,
    deactivate = function(i) boom(i, 'deactivate') end,
    close = function(i) boom(i, 'close') end,
  }

  out[#out + 1] = {
    name = 'greedy',
    define = function(i)
      i:state().count = 0
      -- Section 8.1 puts resource capture in `activate`. `early` NAMES the
      -- call that reaches for it in `define`, because `acquire` and
      -- `release` carry the guard separately.
      local early = T.getv(i:options(), 'early')
      if 'acquire' == early then i:acquire() end
      if 'release' == early then i:release(function() end) end
    end,
    activate = function(i)
      local opts = i:options()
      local n = num(T.getv(opts, 'acquire'))
      local rel = num(T.getv(opts, 'release'))
      local handles = {}
      for _ = 1, n do handles[#handles + 1] = i:acquire() end
      -- Release some explicitly; the DIFFERENCE is what the instance scope
      -- must unwind by itself (section 8.3), and that difference is the
      -- whole test.
      for k = 1, math.min(rel, #handles) do handles[k]() end

      -- `bind` is `early`'s counterpart for section 8.1's OTHER half.
      -- Binding declaration belongs in `define`; this names the callback
      -- that tries it from somewhere else.
      if 'activate' == T.getv(opts, 'bind') then
        i:bind('p', function() end)
      end

      -- `mark` registers N FOREIGN releases - section 8.3's `release`, the
      -- half `acquire` cannot exercise - each recording its own index as
      -- it runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
      -- REVERSE UNWIND FROM A FORWARD ONE.
      i:state().unwound = T.list {}
      local markfail = T.truthy(T.getv(opts, 'markfail'))
      for k = 0, num(T.getv(opts, 'mark')) - 1 do
        i:release(function()
          -- `markfail` makes the release RAISE - the only way section
          -- 8.3's `plugin_release_failed` and its `failed` status are
          -- reachable.
          if markfail then
            error('release failed at ' .. k, 0)
          end
          local list = i:state().unwound
          list[#list + 1] = k
        end)
      end
    end,
    -- `deactivate` completes the pair: the guard is on the PHASE, not on
    -- "not define", and an entry exercising only one leaves the other's
    -- mutation alive.
    deactivate = function(i)
      if 'deactivate' == T.getv(i:options(), 'bind') then
        i:bind('p', function() end)
      end
    end,
  }

  out[#out + 1] = {
    name = 'dep',
    define = function(i)
      i:state().count = 0
      declareprovides(i)
      local exports = T.getv(i:options(), 'exports') or T.map {}
      for _, k in ipairs(T.keys(exports)) do
        i:export(k, exports[k])
      end
    end,
    activate = function(i) i:acquire() end,
  }

  out[#out + 1] = {
    name = 'provider',
    define = function(i)
      i:state().count = 0
      local opts = i:options()
      local point = T.getv(opts, 'point') or 'v'
      i:bind(point, function()
        local o = i:options()
        if T.has(o, 'value') then return o.value end
        return i.ref
      end, T.getv(opts, 'band'))
      declareprovides(i)
    end,
    activate = function(i) i:acquire() end,
  }

  out[#out + 1] = record('slow')
  out[#out + 1] = record('other')
  out[#out + 1] = record('adapter')
  out[#out + 1] = record('late')

  return out
end

local function newhost(cmd)
  cmd = cmd or T.map {}
  return P.make_host(T.map {
    catalog = P.make_catalog(M.probes()),
    reserved = T.getv(cmd, 'reserved'),
    keys = T.getv(cmd, 'keys'),
    defaults = T.getv(cmd, 'defaults'),
    profile = T.getv(cmd, 'profile'),
    points = M.withpoints(T.getv(cmd, 'points')),
    -- Section 11.3's strict reading. Absent means `restart`.
    dependency = T.getv(cmd, 'dependency'),
  })
end

local function docall(host, cmd, ref, point)
  local entry = host:instance(ref)
  if nil == entry then
    T.fail('plugin_not_loaded', 'no such instance: ' .. tostring(ref), nil)
  end
  local method = T.getv(cmd, 'method')

  if 'bump' == method then
    entry.state.count = num(T.getv(entry.state, 'count')) + 1
    return host, M.NOTHING
  end
  if 'count' == method then
    return host, T.getv(entry.state, 'count') or 0
  end
  if 'unwound' == method then
    return host, T.getv(entry.state, 'unwound') or T.list {}
  end
  -- Reached through the instance api, which is where section 6.6 puts it -
  -- a plugin asks about itself.
  if 'position' == method then
    return host, host:positionof(ref, point)
  end
  if 'stray' == method then
    -- A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO DO
    -- NOTHING, and its corpus row stayed green whatever `release` did with
    -- its guard.
    local inst = host:exports(ref .. '/inst')
    inst:release(function() end)
    return host, M.NOTHING
  end
  return host, M.NOTHING
end

local function docmd(host, cmd)
  local ref = T.getv(cmd, 'ref')
  local point = T.getv(cmd, 'point')
  local spec = T.map {
    options = T.getv(cmd, 'options'),
    order = T.getv(cmd, 'order'),
    definition = T.getv(cmd, 'definition'),
    tag = T.getv(cmd, 'tag'),
  }
  local verb = T.getv(cmd, 'do')

  if 'host' == verb then
    return newhost(cmd), M.NOTHING
  end
  -- The catalog is pre-seeded with the probe set; `define` names which
  -- entry backs this definition.
  if 'define' == verb then return host, M.NOTHING end

  if 'load' == verb then
    host:load(ref, spec)
  elseif 'ready' == verb then
    -- declare FIRST, so the ordering block and definition reach the
    -- instance - `ready` walks the staircase, it does not carry
    -- configuration of its own.
    host:declare(ref, spec)
    host:ready(ref)
  elseif 'activate' == verb then
    host:activate(ref)
  elseif 'deactivate' == verb then
    host:deactivate(ref)
  elseif 'unload' == verb then
    host:unload(ref)
  elseif 'apply' == verb then
    host:apply(T.getv(cmd, 'doc'), T.getv(cmd, 'profile'))
  elseif 'options' == verb then
    host:options(ref, T.getv(cmd, 'patch'))
  elseif 'close' == verb then
    host:close()
  elseif 'list' == verb then
    return host, host:list()
  elseif 'emit' == verb then
    return host, host:emit(point, T.getv(cmd, 'arg'))
  elseif 'chain' == verb then
    return host, host:call(point, T.getv(cmd, 'arg'))
  elseif 'provider' == verb then
    return host, host:provider(point, T.getv(cmd, 'arg'))
  elseif 'shadowed' == verb then
    return host, host:shadowed(point)
  elseif 'export' == verb then
    return host, host:exports(T.getv(cmd, 'key'))
  elseif 'capability' == verb then
    return host, host:capability(T.getv(cmd, 'name'))
  elseif 'trace' == verb then
    return host, host:trace()
  elseif 'hostdeclare' == verb then
    -- Section 9.1's host-owned path: the embedding host installing the
    -- instance whose name it reserved.
    return host, host:hostdeclare(ref, spec).ref
  elseif 'declare' == verb then
    return host, host:declare(ref, spec).ref
  elseif 'order' == verb then
    return host, T.list(host:order(point))
  elseif 'seq' == verb then
    local entry = host:instance(ref)
    return host, entry and entry.seq or T.NULL
  elseif 'pos' == verb then
    local entry = host:instance(ref)
    return host, entry and entry.pos or T.NULL
  elseif 'inner' == verb then
    local entry = host:instance(ref)
    if nil == entry or nil == entry.inner then return host, T.NULL end
    return host, entry.inner:list()
  elseif 'call' == verb then
    return docall(host, cmd, ref, point)
  else
    error('unknown driver command: ' .. tostring(verb), 0)
  end

  return host, M.NOTHING
end

-- Run a command list and return section 4.5's observable. Stops at the
-- first raise; the entry's `err` matches its code.
function M.drive(cmds)
  local host = newhost(nil)

  -- Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
  -- ONE. Storing it and continuing - rather than returning at the first
  -- producing command - is what lets an entry emit and then inspect, which
  -- most of `point` needs.
  local last = nil

  for i = 1, T.len(cmds) do
    local cmd = cmds[i]
    local ok, a, b = pcall(docmd, host, cmd)
    if ok then
      host = a
      if M.NOTHING ~= b then last = b end
    else
      -- Section 4.1: `catch` records the raise and lets the run continue,
      -- which is the only way to observe a `failed` instance - section
      -- 5.2's whole claim is that it stays registered and inspectable.
      if true ~= T.getv(cmd, 'catch') then error(a, 0) end
    end
  end
  return host:observable(last)
end

return M
