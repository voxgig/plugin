/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable. */

'use strict'

const { makehost, makecatalog } = require('../src/index')

/** §4.3's six probes. Their behaviour is as much the contract as the
 * runner is — this is where twenty implementations of `noisy` are made
 * to fail at the same callback in the same way. */
function probes() {
  const record = (name) => ({
    name,
    define: (i) => { i.state.count = i.state.count || 0 },
    activate: (i) => { i.acquire() },
  })

  const probe = {
    name: 'probe',
    define: (i) => {
      i.state.count = i.state.count || 0
      // One hook binding (`p`) and one chain wrap (`c`) — the workhorse
      // shape DOCS.md §4.3 specifies.
      i.bind('p', () => { i.state.count = (i.state.count || 0) + 1 },
        i.options && i.options.band)
      // Wrap AFTER next, so the result spells the nesting left to right:
      // outermost first. Wrapping the ARGUMENT instead would spell it
      // backwards and make every chain expectation read wrong.
      i.bind('c', (next, v) => (i.options && i.options.wrap ? i.options.wrap : ':') + next(v),
        i.options && i.options.band)
      i.export('client', i.ref)
      // The instance api itself, so the driver's `stray` command can
      // call `release` from OUTSIDE a lifecycle callback.
      i.export('inst', i)
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
    },
    activate: (i) => {
      i.acquire()
      // §6.5: an instance that is itself a host. The outer owns the
      // inner's lifetime — registered in the scope, so it closes on
      // deactivate in the same reverse unwind as every other resource.
      if (i.options && i.options.nest) {
        const inner = i.nest({ points: withpoints() })
        for (const d of probes()) inner.catalog.add(d)
        for (const r of i.options.nest) inner.ready(r)
      }
    },
  }

  const noisy = {
    name: 'noisy',
    define: (i) => {
      i.state.count = i.state.count || 0
      boom(i, 'define')
    },
    activate: (i) => {
      // Acquire BEFORE the raise, so a failing activate has something to
      // leak if the scope does not unwind — which is the whole point of
      // the entry that asserts open === 0 afterwards.
      i.acquire()
      reenter(i, 'activate')
      boom(i, 'activate')
    },
    deactivate: (i) => boom(i, 'deactivate'),
    close: (i) => boom(i, 'close'),
  }

  const greedy = {
    name: 'greedy',
    define: (i) => {
      i.state.count = 0
      // §8.1 puts resource capture in `activate`. `early` NAMES the call
      // that reaches for it in `define`, because `acquire` and `release`
      // carry the guard separately.
      if (i.options && 'acquire' === i.options.early) i.acquire()
      if (i.options && 'release' === i.options.early) i.release(() => undefined)
    },
    activate: (i) => {
      const n = i.options.acquire || 0
      const rel = i.options.release || 0
      const handles = []
      for (let k = 0; k < n; k++) handles.push(i.acquire())
      // Release some explicitly; the DIFFERENCE is what the instance
      // scope must unwind by itself (§8.3), and that difference is the
      // whole test.
      for (let k = 0; k < rel; k++) handles[k]()

      // `mark` registers N FOREIGN releases — §8.3's `release`, the half
      // `acquire` cannot exercise — each recording its own index as it
      // runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
      // REVERSE UNWIND FROM A FORWARD ONE.
      // `bind` is `early`'s counterpart for §8.1's OTHER half. Binding
      // declaration belongs in `define`; this names the callback that
      // tries it from somewhere else.
      if ('activate' === i.options.bind) i.bind('p', () => undefined)

      const mark = i.options.mark || 0
      i.state.unwound = []
      for (let k = 0; k < mark; k++) {
        i.release(() => {
          // `markfail` makes the release RAISE — the only way §8.3's
          // `plugin_release_failed` and its `failed` status are
          // reachable.
          if (i.options.markfail) throw new Error('release failed at ' + k)
          i.state.unwound.push(k)
        })
      }
    },
    // `deactivate` completes the pair: the guard is on the PHASE, not on
    // "not define", and an entry exercising only one leaves the other's
    // mutation alive.
    deactivate: (i) => {
      if (i.options && 'deactivate' === i.options.bind) i.bind('p', () => undefined)
    },
  }

  const dep = {
    name: 'dep',
    define: (i) => {
      i.state.count = 0
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
      if (i.options && i.options.exports) {
        for (const k of Object.keys(i.options.exports)) i.export(k, i.options.exports[k])
      }
    },
    activate: (i) => { i.acquire() },
  }

  const provider = {
    name: 'provider',
    define: (i) => {
      i.state.count = 0
      const point = (i.options && i.options.point) || 'v'
      i.bind(point, () => (i.options && undefined !== i.options.value ? i.options.value : i.ref),
        i.options && i.options.band)
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
    },
    activate: (i) => { i.acquire() },
  }

  return [probe, noisy, greedy, dep, provider, record('slow'),
    record('other'), record('adapter'), record('late')]
}

function boom(i, cb) {
  if (i.options && cb === i.options.fail) {
    // `bare` raises WITHOUT a code — the ordinary library error §12's
    // `plugin_<phase>_failed` codes exist to wrap.
    if (i.options.bare) throw new Error('probe failed at ' + cb)
    const err = new Error('probe failed at ' + cb)
    err.code = i.options.code || 'plugin_' + cb + '_failed'
    throw err
  }
}

function reenter(i, cb) {
  if (i.options && cb === i.options.reenter) {
    // A transition from inside a lifecycle callback (§5.2).
    i.host().activate(i.ref)
  }
}

/** The points every driver host declares. DOCS.md §4.3 defines `probe`
 * as binding one hook point (`p`) and wrapping one chain point (`c`), so
 * a host without them cannot load the probe at all — they are part of
 * the contract's baseline rather than a fixture convenience. `v` is the
 * provider point the `provider` probe defaults to. */
const BASEPOINTS = {
  p: { kind: 'hook' },
  c: { kind: 'chain', base: (v) => v },
  v: { kind: 'provider' },
}

function withpoints(extra) {
  const out = {}
  for (const k of Object.keys(BASEPOINTS)) out[k] = BASEPOINTS[k]
  for (const k of Object.keys(extra || {})) {
    // A `host` command REPLACES a base point rather than merging into
    // it, so an entry can redeclare `c` with its own base or `v` as
    // exclusive without inheriting the default's shape.
    out[k] = extra[k]
  }
  return out
}

function withprobes() {
  return makecatalog(probes())
}

/** Run a command list and return §4.5's observable. Stops at the first
 * raise; the entry's `err` matches its code. */
function drive(cmds) {
  let host = makehost({ catalog: withprobes(), points: withpoints() })

  // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
  // Storing it and continuing — rather than returning at the first
  // producing command — is what lets an entry emit and then inspect,
  // which most of `point` needs.
  let last = undefined

  for (const c of cmds) {
    try {
      switch (c.do) {
        case 'host':
          host = makehost({
            catalog: withprobes(),
            reserved: c.reserved, keys: c.keys, defaults: c.defaults,
            profile: c.profile, points: withpoints(c.points),
            // §11.3's strict reading. Absent means `restart`.
            dependency: c.dependency,
          })
          break
        case 'define':
          // The catalog is pre-seeded with the probe set; `define` names
          // which entry backs this definition.
          break
        case 'load':
          host.load(c.ref, { options: c.options, order: c.order, definition: c.definition })
          break
        case 'ready':
          // declare FIRST, so the ordering block and definition reach
          // the instance — `ready` walks the staircase, it does not
          // carry configuration of its own.
          host.declare(c.ref, { options: c.options, order: c.order, definition: c.definition })
          host.ready(c.ref)
          break
        case 'activate': host.activate(c.ref); break
        case 'deactivate': host.deactivate(c.ref); break
        case 'unload': host.unload(c.ref); break
        case 'apply': host.apply(c.doc, c.profile); break
        case 'options': host.options(c.ref, c.patch); break
        case 'close': host.close(); break
        case 'list': last = host.list(); break
        case 'emit': last = host.emit(c.point, c.arg); break
        case 'chain': last = host.call(c.point, c.arg); break
        case 'provider': last = host.provider(c.point, c.arg); break
        case 'shadowed': last = host.shadowed(c.point); break
        case 'export': last = host.exports(c.key); break
        case 'capability': last = host.capability(c.name); break
        case 'trace': last = host.trace(); break
        case 'hostdeclare':
          // §9.1's host-owned path: the embedding host installing the
          // instance whose name it reserved.
          last = host.hostdeclare(c.ref, {
            tag: c.tag, options: c.options, order: c.order, definition: c.definition,
          }).ref
          break
        case 'declare':
          last = host.declare(c.ref, {
            tag: c.tag, options: c.options, order: c.order, definition: c.definition,
          }).ref
          break
        case 'seq': {
          const e = host.instance(c.ref)
          last = e ? e.seq : null
          break
        }
        case 'pos': {
          const e = host.instance(c.ref)
          last = e ? e.pos : null
          break
        }
        case 'inner': {
          const e = host.instance(c.ref)
          last = e && e.inner ? e.inner.list() : null
          break
        }
        case 'order': last = host.order(c.point); break
      case 'selected':
        // §11.4's remembered choice, read directly. Every other
        // observable — status, log, even `hold` — is identical under a
        // host that re-ranks on every question.
        last = host.selectedof(c.ref, c.name)
        break
        case 'call': {
          const e = host.instance(c.ref)
          if (!e) {
            const err = new Error('no such instance')
            err.code = 'plugin_not_loaded'
            throw err
          }
          if ('bump' === c.method) { e.state.count = (e.state.count || 0) + 1; break }
          if ('count' === c.method) { last = e.state.count || 0; break }
          if ('unwound' === c.method) { last = e.state.unwound || []; break }
          if ('position' === c.method) {
            // Reached through the instance api, which is where §6.6 puts
            // it — a plugin asks about itself.
            last = host.positionof(c.ref, c.point)
            break
          }
          if ('stray' === c.method) {
            // A release from OUTSIDE a lifecycle callback. THIS BRANCH
            // USED TO DO NOTHING, and its corpus row stayed green
            // whatever `release` did with its guard.
            host.exports(c.ref + '/inst').release(() => undefined)
            break
          }
          break
        }
        default:
          throw new Error('unknown driver command: ' + c.do)
      }
    }
    catch (err) {
      // §4.1: `catch` records the raise and lets the run continue, which
      // is the only way to observe a `failed` instance — §5.2's whole
      // claim is that it stays registered and inspectable.
      if (true !== c.catch) throw err
    }
  }
  return host.observable(last)
}

module.exports = { probes, drive }
