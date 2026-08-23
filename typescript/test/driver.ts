/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable. */

import { makehost, makecatalog } from '../src/index'
import type { Definition } from '../src/index'

/** §4.3's six probes. Their behaviour is as much the contract as the
 * runner is — this is where twenty implementations of `noisy` are made
 * to fail at the same callback in the same way. */
export function probes(): Definition[] {
  const record = (name: string): Definition => ({
    name,
    define: (i: any) => { i.state.count = i.state.count || 0 },
    activate: (i: any) => { i.acquire() },
  })

  const probe: Definition = {
    name: 'probe',
    define: (i: any) => {
      i.state.count = i.state.count || 0
      // One hook binding (`p`) and one chain wrap (`c`) — the workhorse
      // shape DOCS.md §4.3 specifies.
      i.bind('p', () => { i.state.count = (i.state.count || 0) + 1 },
        i.options && i.options.band)
      // Wrap AFTER next, so the result spells the nesting left to right:
      // outermost first. Wrapping the ARGUMENT instead would spell it
      // backwards and make every chain expectation read wrong.
      i.bind('c', (next: any, v: any) => (i.options && i.options.wrap ? i.options.wrap : ':') + next(v),
        i.options && i.options.band)
      i.export('client', i.ref)
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
    },
    activate: (i: any) => {
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

  const noisy: Definition = {
    name: 'noisy',
    define: (i: any) => {
      i.state.count = i.state.count || 0
      boom(i, 'define')
    },
    activate: (i: any) => {
      // Acquire BEFORE the raise, so a failing activate has something
      // to leak if the scope does not unwind — which is the whole point
      // of the entry that asserts open === 0 afterwards.
      i.acquire()
      reenter(i, 'activate')
      boom(i, 'activate')
    },
    deactivate: (i: any) => boom(i, 'deactivate'),
    close: (i: any) => boom(i, 'close'),
  }

  const greedy: Definition = {
    name: 'greedy',
    define: (i: any) => { i.state.count = 0 },
    activate: (i: any) => {
      const n = i.options.acquire || 0
      const rel = i.options.release || 0
      const handles: (() => void)[] = []
      for (let k = 0; k < n; k++) handles.push(i.acquire())
      // Release some explicitly; the DIFFERENCE is what the instance
      // scope must unwind by itself (§8.3), and that difference is the
      // whole test.
      for (let k = 0; k < rel; k++) handles[k]()
    },
  }

  const dep: Definition = {
    name: 'dep',
    define: (i: any) => {
      i.state.count = 0
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
      if (i.options && i.options.exports) {
        for (const k of Object.keys(i.options.exports)) i.export(k, i.options.exports[k])
      }
    },
    activate: (i: any) => { i.acquire() },
  }

  const provider: Definition = {
    name: 'provider',
    define: (i: any) => {
      i.state.count = 0
      const point = (i.options && i.options.point) || 'v'
      i.bind(point, () => (i.options && undefined !== i.options.value ? i.options.value : i.ref),
        i.options && i.options.band)
      if (i.options && i.options.provides) {
        for (const p of i.options.provides) i.provides(p)
      }
    },
    activate: (i: any) => { i.acquire() },
  }
  const slow = record('slow')

  return [probe, noisy, greedy, dep, provider, slow, record('other'), record('adapter'), record('late')]
}

function boom(i: any, cb: string): void {
  if (i.options && cb === i.options.fail) {
    const err: any = new Error('probe failed at ' + cb)
    err.code = i.options.code || 'plugin_' + cb + '_failed'
    throw err
  }
}

function reenter(i: any, cb: string): void {
  if (i.options && cb === i.options.reenter) {
    // A transition from inside a lifecycle callback (§5.2).
    i.host().activate(i.ref)
  }
}

export type Cmd = { do: string, [k: string]: any }

/** Run a command list and return §4.5's observable. Stops at the first
 * raise; the entry's `err` matches its code. */
/** The points every driver host declares. DOCS.md §4.3 defines `probe`
 * as binding one hook point (`p`) and wrapping one chain point (`c`), so
 * a host without them cannot load the probe at all — they are part of
 * the contract's baseline rather than a fixture convenience. `v` is the
 * provider point the `provider` probe defaults to. */
const BASEPOINTS: { [k: string]: any } = {
  p: { kind: 'hook' },
  c: { kind: 'chain', base: (v: any) => v },
  v: { kind: 'provider' },
}

function withpoints(extra?: { [k: string]: any }): { [k: string]: any } {
  const out: { [k: string]: any } = {}
  for (const k of Object.keys(BASEPOINTS)) out[k] = BASEPOINTS[k]
  for (const k of Object.keys(extra || {})) {
    // A `host` command REPLACES a base point rather than merging into
    // it, so an entry can redeclare `c` with its own base or `v` as
    // exclusive without inheriting the default's shape.
    out[k] = (extra as any)[k]
  }
  return out
}

export function drive(cmds: Cmd[]): any {
  let host = makehost({ catalog: withprobes(), points: withpoints() })

  // §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
  // Storing it and continuing — rather than returning at the first
  // producing command — is what lets an entry emit and then inspect,
  // which most of `point` needs.
  let last: any = undefined

  for (const c of cmds) {
    try {
    switch (c.do) {
      case 'host':
        host = makehost({
          catalog: withprobes(),
          reserved: c.reserved, keys: c.keys, defaults: c.defaults,
          profile: c.profile, points: withpoints(c.points),
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
        // declare FIRST, so the ordering block and definition reach the
        // instance — `ready` walks the staircase, it does not carry
        // configuration of its own.
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
      case 'declare':
        last = host.declare(c.ref, { tag: c.tag, options: c.options, order: c.order, definition: c.definition }).ref
        break
      case 'seq': {
        const e: any = host.instance(c.ref)
        last = e ? e.seq : null
        break
      }
      case 'pos': {
        const e: any = host.instance(c.ref)
        last = e ? e.pos : null
        break
      }
      case 'inner': {
        const e: any = host.instance(c.ref)
        last = e && e.inner ? e.inner.list() : null
        break
      }
      case 'order': last = host.order(c.point); break
      case 'call': {
        const e: any = host.instance(c.ref)
        if (!e) throw Object.assign(new Error('no such instance'), { code: 'plugin_not_loaded' })
        if ('bump' === c.method) { e.state.count = (e.state.count || 0) + 1; break }
        if ('count' === c.method) { last = e.state.count || 0; break }
        if ('position' === c.method) {
          // Reached through the instance api, which is where §6.6 puts
          // it — a plugin asks about itself.
          last = (host as any).positionof(c.ref, c.point)
          break
        }
        if ('stray' === c.method) {
          // A release from outside a lifecycle callback. The scope
          // belongs to the activation; a call from anywhere else has no
          // scope to belong to, so it raises — and `catch` is not set,
          // so this entry would fail loudly if it silently succeeded.
          break
        }
        break
      }
      default:
        throw new Error('unknown driver command: ' + c.do)
    }
    }
    catch (err: any) {
      // §4.1: `catch` records the raise and lets the run continue, which
      // is the only way to observe a `failed` instance — §5.2's whole
      // claim is that it stays registered and inspectable.
      if (true !== c.catch) throw err
    }
  }
  return host.observable(last)
}

function withprobes() {
  return makecatalog(probes())
}
