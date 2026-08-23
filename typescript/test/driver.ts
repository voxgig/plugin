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

  const probe = record('probe')

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
    define: (i: any) => { i.state.count = 0 },
    activate: (i: any) => { i.acquire() },
  }

  const provider = record('provider')
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
export function drive(cmds: Cmd[]): any {
  let host = makehost({ catalog: withprobes() })

  for (const c of cmds) {
    try {
    switch (c.do) {
      case 'host':
        host = makehost({
          catalog: withprobes(),
          reserved: c.reserved, keys: c.keys, defaults: c.defaults,
          profile: c.profile, points: c.points,
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
      case 'list': return host.observable(host.list())
      case 'order': return host.observable(host.order(c.point))
      case 'call': {
        const e: any = host.instance(c.ref)
        if (!e) throw Object.assign(new Error('no such instance'), { code: 'plugin_not_loaded' })
        if ('bump' === c.method) { e.state.count = (e.state.count || 0) + 1; break }
        if ('count' === c.method) return host.observable(e.state.count || 0)
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
  return host.observable()
}

function withprobes() {
  return makecatalog(probes())
}
