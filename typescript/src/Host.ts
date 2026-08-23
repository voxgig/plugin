/* The host: the lifecycle state machine (§5), extension points (§6),
 * and resource capture (§8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order,
 * never interleaved; a transition triggered from inside a lifecycle
 * callback is `plugin_reentrant`. A hard rule, because it is the only
 * way the semantics can be identical in Go, in Ruby and in
 * single-threaded JavaScript.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by
 * suspending on a promise. Every port must be able to do the same, and
 * fourteen of them will not have JavaScript's event loop. */

import { Status, Instance, OrderBlock, fail } from './Types'
import { canonref, parseref } from './Ref'
import { Catalog, Definition, makecatalog } from './Catalog'
import { resolveorder, Binding, Pin } from './Order'
import { normalizeconfig, resolveoptions } from './Config'

export type PointSpec = { kind?: 'hook' | 'chain' | 'provider', pin?: Pin }

export type HostOptions = {
  catalog?: Catalog
  reserved?: string[]
  keys?: { instance?: string, default?: string }
  defaults?: { [name: string]: any }
  profile?: string
  points?: { [point: string]: PointSpec }
}

type Live = {
  ref: string
  def: Definition
  status: Status
  pos: number
  seq: number
  options: any
  state: any
  order?: OrderBlock
  /** Requirements this instance declared but has not been given. */
  unmet: string[]
  /** Resources the instance scope holds, newest last — unwound in
   * REVERSE, because that is the only order in which teardown mirrors
   * setup (§8.3). */
  scope: (() => void)[]
}

export type Host = ReturnType<typeof makehost>

export function makehost(options?: HostOptions) {
  const opts = options || {}
  const catalog = opts.catalog || makecatalog()
  const reserved = opts.reserved || []
  const points = opts.points || {}

  const inst: { [ref: string]: Live } = {}
  const log: string[] = []
  let seqn = 0
  let open = 0
  let intransition = false

  // --- observation -------------------------------------------------

  /** Introspection NEVER advances the state (§5.2). A status page must
   * not be a way to accidentally import twenty packages. */
  const list = (): { [ref: string]: Status } => {
    const out: { [ref: string]: Status } = {}
    for (const r of Object.keys(inst).sort()) out[r] = inst[r].status
    return out
  }

  const instance = (ref: string): Live | undefined => inst[canonref(ref)]

  const observable = (result?: any) => ({
    status: list(),
    open,
    log: log.slice(),
    result: undefined === result ? null : result,
  })

  // --- the state machine -------------------------------------------

  function guard(): void {
    if (intransition) {
      fail('plugin_reentrant', 'transition attempted from inside a lifecycle callback')
    }
  }

  function need(ref: string): Live {
    const r = canonref(ref)
    const e = inst[r]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + r, { ref: r })
    return e
  }

  function checkreserved(ref: string): void {
    if (0 === reserved.length) return
    if (-1 !== reserved.indexOf(parseref(ref).name)) {
      fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
    }
  }

  function run(e: Live, cb: keyof Definition, phase: string): void {
    const fn = e.def[cb] as any
    log.push(e.ref + ':' + phase)
    if ('function' !== typeof fn) return
    intransition = true
    try {
      fn(api(e))
    }
    finally {
      intransition = false
    }
  }

  /** What a definition's callbacks see. Deliberately not the internal
   * record: a plugin that could reach `status` could also write it. */
  function api(e: Live) {
    return {
      ref: e.ref,
      name: parseref(e.ref).name,
      tag: parseref(e.ref).tag,
      options: e.options,
      state: e.state,
      /** Foreign resources the host did not hand out are registered
       * explicitly (§8.3); host calls are recorded automatically. */
      release: (fn: () => void) => {
        if (!intransition) {
          fail('plugin_release_scope', 'release called outside activate')
        }
        e.scope.push(fn)
        open += 1
      },
      /** The synthetic counter the driver owns, so "what is open" is
       * data rather than an assertion each port words differently.
       *
       * Returns its own release, so a plugin can hand one back early.
       * The scope still holds the entry and unwinding it twice is a
       * no-op — releasing early must not make teardown wrong. */
      acquire: (): (() => void) => {
        if (!intransition) {
          fail('plugin_release_scope', 'acquire called outside activate')
        }
        let done = false
        const rel = () => { if (!done) { done = true; open -= 1 } }
        e.scope.push(rel)
        open += 1
        return rel
      },
      host: () => self,
    }
  }

  function declare(ref: string, spec?: { definition?: string, options?: any, order?: OrderBlock, pos?: number }): Live {
    const r = canonref(ref)
    checkreserved(r)
    const s = spec || {}
    const defname = s.definition || parseref(r).name
    const def = catalog.get(defname)
    if (!def) {
      fail('plugin_unknown_definition', 'not in catalog: ' + defname, { name: defname })
    }

    const existing = inst[r]
    if (existing) {
      // §4 rule 1: a pair addresses at most one instance. Re-declaring
      // the SAME definition is the idempotent case; a different one is
      // a duplicate, not a silent overwrite (seneca) and not an
      // impossibility (sdkgen).
      if (existing.def.name !== def.name) {
        fail('plugin_ref_duplicate', 'instance already declared: ' + r, { ref: r })
      }
      return existing
    }

    const e: Live = {
      ref: r, def, status: 'declared',
      pos: undefined === s.pos ? Object.keys(inst).length : s.pos,
      seq: seqn++,
      options: s.options || {},
      state: {}, order: s.order, unmet: [], scope: [],
    }
    inst[r] = e
    return e
  }

  function load(ref: string, spec?: any): Live {
    guard()
    const e = declare(ref, spec)
    if ('declared' !== e.status) return e   // idempotent in the trivial direction
    if (spec && spec.options) e.options = spec.options
    try {
      run(e, 'define', 'define')
    }
    catch (err: any) {
      e.status = 'failed'
      throw err
    }
    e.status = 'loaded'
    return e
  }

  function activate(ref: string): Live {
    guard()
    const e = need(ref)
    if ('live' === e.status) return e        // no-op returning success
    if ('failed' === e.status) {
      fail('plugin_bad_state', 'instance has failed: ' + e.ref, { ref: e.ref })
    }
    if ('declared' === e.status) load(e.ref)

    // A declared requirement that is not live means `pending`:
    // activation is a STANDING REQUEST, not a one-shot event.
    if (0 < unmetof(e).length) {
      e.unmet = unmetof(e)
      e.status = 'pending'
      return e
    }

    try {
      run(e, 'activate', 'activate')
    }
    catch (err: any) {
      // Unwind whatever the partial activation captured, in reverse.
      unwind(e)
      e.status = 'failed'
      throw err
    }
    e.status = 'live'
    reconcile()
    return e
  }

  function deactivate(ref: string): Live {
    guard()
    const e = need(ref)
    if ('loaded' === e.status || 'declared' === e.status) return e

    if ('pending' === e.status) {
      // DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
      // never reached activate, so it holds no scope and no live
      // bindings; running the definition's deactivate there would be
      // teardown without matching setup, which plugins are not written
      // to survive and which could fail an instance that had done
      // nothing wrong. It cannot fail.
      e.status = 'loaded'
      e.unmet = []
      return e
    }

    try {
      run(e, 'deactivate', 'deactivate')
      unwind(e)
    }
    catch (err: any) {
      unwind(e)
      e.status = 'failed'
      throw err
    }
    e.status = 'loaded'
    reconcile()
    return e
  }

  function unload(ref: string): void {
    guard()
    const e = need(ref)
    if ('live' === e.status || 'pending' === e.status) {
      if ('live' === e.status) {
        run(e, 'deactivate', 'deactivate')
        unwind(e)
      }
      e.status = 'loaded'
    }
    if ('loaded' === e.status || 'failed' === e.status) {
      try { run(e, 'close', 'close') }
      finally { delete inst[e.ref] }
      return
    }
    delete inst[e.ref]
  }

  function ready(ref: string): Live {
    // Runs the whole forward path in one call (§5.1). §15.2's verb list
    // omits this; §5.1 defines it and §15.3's `declare` row requires the
    // corpus to pin it, so the list was incomplete rather than
    // excluding it (DOCS.md §4.2).
    guard()
    const r = canonref(ref)
    if (!inst[r]) declare(r)
    if ('declared' === inst[r].status) load(r)
    return activate(r)
  }

  /** Bindings go live only when activation succeeds (§8.1), so the
   * teardown is the exact inverse: reverse order, always. */
  function unwind(e: Live): void {
    for (let i = e.scope.length - 1; 0 <= i; i--) {
      try { e.scope[i]() } catch (err) { /* a failing release is §12's problem, not a leak here */ }
    }
    e.scope = []
  }

  function unmetof(e: Live): string[] {
    const req: string[] = (e.options && e.options.requires) || []
    return req.filter((r: string) => {
      const t = inst[canonref(r)]
      return !t || 'live' !== t.status
    })
  }

  /** EAGER reconciliation: run to a fixed point rather than scheduling.
   * A pending instance whose requirement arrives activates without
   * being asked again. */
  function reconcile(): void {
    let moved = true
    let rounds = 0
    while (moved) {
      moved = false
      if (1000 < ++rounds) break
      for (const r of Object.keys(inst).sort()) {
        const e = inst[r]
        if ('pending' !== e.status) continue
        if (0 < unmetof(e).length) continue
        try {
          run(e, 'activate', 'activate')
          e.status = 'live'
          e.unmet = []
          moved = true
        }
        catch (err) {
          unwind(e)
          e.status = 'failed'
          moved = true
        }
      }
    }
  }

  // --- ordering ----------------------------------------------------

  function order(point?: string): string[] {
    const bindings: Binding[] = Object.keys(inst)
      .filter((r) => 'live' === inst[r].status)
      .map((r) => ({ ref: r, pos: inst[r].pos, order: inst[r].order }))
    const spec = point ? points[point] : undefined
    return resolveorder(bindings, spec && spec.pin)
  }

  // --- documents ---------------------------------------------------

  function apply(doc: any, profile?: string): void {
    guard()
    const norm = normalizeconfig({
      doc, profile: profile || opts.profile,
      keys: opts.keys, reserved,
    })

    for (let i = 0; i < norm.order.length; i++) {
      const ref = norm.order[i]
      const ent: Instance = norm.instance[ref]
      const options = resolveoptions({
        ref, doc, profile: profile || opts.profile,
        shape: shapeof(ref), hostdefaults: opts.defaults && opts.defaults[parseref(ref).name],
      })

      const existing = inst[ref]
      const wantlive = ent.active && 'eager' === ent.start

      // Toggling back to lazy or inactive returns it to `declared`, BY
      // UNLOADING IT (§9.6). There is no loaded->declared transition and
      // there should not be one: going back to `declared` means "as if
      // never loaded", and an instance that has run `define` has state
      // and bindings that only `close` can properly undo.
      if (existing && !wantlive && 'declared' !== existing.status) {
        unload(ref)
      }

      declare(ref, { options, order: ent.order, pos: ent.pos })
      inst[ref].options = options
      inst[ref].order = ent.order
      inst[ref].pos = ent.pos

      if (wantlive) ready(ref)
    }
  }

  function shapeof(ref: string): any {
    const def = catalog.get(parseref(ref).name)
    return def && def.shape
  }

  function setoptions(ref: string, patch: any): void {
    guard()
    const e = need(ref)
    const previous = e.options
    e.options = resolveoptions({ ref: e.ref, shape: shapeof(e.ref), doc: {}, patch: merge(previous, patch) })
    if ('live' === e.status) {
      if ('function' === typeof e.def.reconfigure) {
        intransition = true
        try { e.def.reconfigure(api(e), e.options, previous) }
        finally { intransition = false }
      }
      else {
        // Always correct and sometimes expensive; `reconfigure` exists
        // to make the common case cheap (§9.4).
        deactivate(e.ref)
        activate(e.ref)
      }
    }
  }

  function merge(a: any, b: any): any {
    const out: any = {}
    for (const k of Object.keys(a || {})) out[k] = a[k]
    for (const k of Object.keys(b || {})) out[k] = b[k]
    return out
  }

  function close(): void {
    for (const r of Object.keys(inst).sort().reverse()) unload(r)
  }

  const self = {
    catalog, list, instance, order, observable,
    declare, load, activate, deactivate, unload, ready, apply, close,
    options: setoptions,
    define: (def: Definition) => catalog.add(def),
  }
  return self
}
