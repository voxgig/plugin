/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable. */

import { makehost, makecatalog } from '../dist/index'
import type { Definition } from '../dist/index'

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
      i.bind('p', () => { i.state.count = (i.state.count || 0) + 1 },
        i.options && i.options.band)
      // Wrap AFTER next, so the result spells the nesting left to right:
      // outermost first. Wrapping the ARGUMENT instead would spell it
      // backwards and make every chain expectation read wrong.
      i.bind('c', (next: any, v: any) => (i.options && i.options.wrap ? i.options.wrap : ':') + next(v),
        i.options && i.options.band)
      i.export('client', i.ref)
      i.export('mark', 'marked')
      // The instance api itself, so the driver's `stray` command can
      // call `release` from OUTSIDE a lifecycle callback — which is the
      // only way to exercise §8.3's scope guard, and which the command
      // claimed to do while being a no-op.
      i.export('inst', i)
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
      i.acquire()
      reenter(i, 'activate')
      boom(i, 'activate')
    },
    deactivate: (i: any) => boom(i, 'deactivate'),
    close: (i: any) => boom(i, 'close'),
  }

  const greedy: Definition = {
    name: 'greedy',
    define: (i: any) => {
      i.state.count = 0
      if (i.options && 'acquire' === i.options.early) i.acquire()
      if (i.options && 'release' === i.options.early) i.release(() => undefined)
    },
    activate: (i: any) => {
      const n = i.options.acquire || 0
      const rel = i.options.release || 0
      const handles: (() => void)[] = []
      for (let k = 0; k < n; k++) handles.push(i.acquire())
      for (let k = 0; k < rel; k++) handles[k]()

      if ('activate' === i.options.bind) i.bind('p', () => undefined)

      const mark = i.options.mark || 0
      i.state.unwound = []
      for (let k = 0; k < mark; k++) {
        i.release(() => {
          if (i.options.markfail) throw new Error('release failed at ' + k)
          i.state.unwound.push(k)
        })
      }
    },
  }

  greedy.deactivate = (i: any) => {
    if (i.options && 'deactivate' === i.options.bind) i.bind('p', () => undefined)
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
    activate: (i: any) => {
      i.acquire()
      if (i.options && i.options.capof) {
        i.export('cap', i.capability(i.options.capof))
      }
    },
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
    // `bare` raises WITHOUT a code — an ordinary library error escaping
    // a callback, which is the case §12's `plugin_<phase>_failed` codes
    // exist to wrap and which nothing exercised while every probe raise
    // carried a code of its own.
    if (i.options.bare) throw new Error('probe failed at ' + cb)
    const err: any = new Error('probe failed at ' + cb)
    err.code = i.options.code || 'plugin_' + cb + '_failed'
    throw err
  }
}

function reenter(i: any, cb: string): void {
  if (i.options && cb === i.options.reenter) {
    i.host().activate(i.ref)
  }
}

export type Cmd = { do: string, [k: string]: any }

const BASEPOINTS: { [k: string]: any } = {
  p: { kind: 'hook' },
  c: { kind: 'chain', base: (v: any) => v },
  v: { kind: 'provider' },
}

function withpoints(extra?: { [k: string]: any }): { [k: string]: any } {
  const out: { [k: string]: any } = {}
  for (const k of Object.keys(BASEPOINTS)) out[k] = BASEPOINTS[k]
  for (const k of Object.keys(extra || {})) {
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
          // §11.3's strict reading. Absent means `restart`, which is
          // the default precisely because a station that cannot swap a
          // provider without a restart has lost the argument for
          // having a plugin system.
          dependency: c.dependency,
        })
        break
      case 'define': {
        const from = undefined === c.probe ? c.name : c.probe
        let def: any = { name: c.name }
        for (const d of probes()) if (from === d.name) def = { ...d, name: c.name }
        if (undefined !== c.shape) def.shape = c.shape
        host.define(def)
        break
      }
      case 'load':
        host.load(c.ref, { options: c.options, order: c.order, definition: c.definition })
        break
      case 'ready':
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
        last = (host as any).hostdeclare(c.ref, {
          tag: c.tag, options: c.options, order: c.order, definition: c.definition,
        }).ref
        break
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
        if ('unwound' === c.method) { last = e.state.unwound || []; break }
        if ('position' === c.method) {
          last = (host as any).positionof(c.ref, c.point)
          break
        }
        if ('stray' === c.method) {
          const strayapi: any = host.exports(c.ref + '/inst')
          strayapi.release(() => undefined)
          break
        }
        break
      }
      default:
        throw new Error('unknown driver command: ' + c.do)
    }
    }
    catch (err: any) {
      if (true !== c.catch) throw err
    }
  }
  return host.observable(last)
}

function withprobes() {
  return makecatalog(probes())
}
