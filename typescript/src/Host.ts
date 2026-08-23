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
import { canonref, parseref, formatref } from './Ref'
import { Catalog, Definition, makecatalog } from './Catalog'
import { resolveorder, Binding, Pin } from './Order'
import { Spec, Bound, Mode, emit as fanout, compose, provider as pickone } from './Point'
import { Exported, resolveexport } from './Export'
import { Provided, Required, Candidate, resolvecapability } from './Capability'
import { normalizeconfig, resolveoptions } from './Config'

export type PointSpec = Spec

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
  /** Declared in `define`, inserted only when activation SUCCEEDS
   * (§8.1). Holding them until then is what makes a failed activate
   * leave nothing behind. */
  bindings: Bound[]
  /** Set when this instance is itself a host (§6.5). */
  inner?: any
  /** Declared in `define`, and VISIBLE while merely `loaded` (§11):
   * they are data, and hiding them would make the loaded state useless
   * for introspection. */
  exports: { [key: string]: any }
  provides: Provided[]
}

export type Host = ReturnType<typeof makehost>

export function makehost(options?: HostOptions) {
  const opts = options || {}
  const catalog = opts.catalog || makecatalog()
  const reserved = opts.reserved || []
  const points = opts.points || {}

  const inst: { [ref: string]: Live } = {}
  const log: string[] = []
  /** §14: the lifecycle event record. `seq` distinguishes ONE
   * INCARNATION of stripe$test from the next, which is the whole reason
   * it is not `pos` (§4 rule 4). */
  const events: { ref: string, event: string, seq: number, status: Status }[] = []
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
    events.push({ ref: e.ref, event: phase, seq: e.seq, status: e.status })
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

      /** Bind into a host point. Declared in `define`; the host inserts
       * it only after `activate` returns successfully (§8.1), which is
       * why a failing activate leaves no live binding behind. */
      bind: (point: string, fn: any, band?: number) => {
        if (undefined === points[point]) {
          fail('plugin_point_unknown', 'no such point: ' + point, { point })
        }
        e.bindings.push({ ref: e.ref, point, fn, band: band || 0 })
      },

      /** Published for other plugins and for the application (§11). */
      export: (key: string, value: any) => { e.exports[key] = value },

      /** What this instance can do for others (§11.1). */
      provides: (p: Provided) => { e.provides.push(p) },

      /** Where this binding landed (§6.6) — the plugin-side counterpart
       * to a host pin. Station found that a plugin can need to KNOW it
       * is in the right place: its middleware must sit immediately
       * outside the base transport or its "wire truth" events are
       * fiction.
       *
       * THE HOST DOES NOT POLICE THIS; it just makes the fact
       * available. A plugin that requires a position it did not get
       * fails loudly rather than reporting nonsense — and that is the
       * plugin's call, because only it knows what its position means.
       * Verification tells a plugin it was misplaced; a pin (§7) stops
       * the misplacement from being expressible at all. The two are not
       * substitutes. */
      position: (point: string) => {
        const ranked = order(point)
        const index = ranked.indexOf(e.ref)
        return {
          index,
          count: ranked.length,
          // §6.2 composes b1(b2(b3(base))) with the FIRST binding
          // OUTERMOST, so these are not index 0 and index count-1 the
          // other way round. Getting this backwards is the exact error
          // the positional pin vocabulary exists to prevent.
          outermost: 0 === index,
          innermost: index === ranked.length - 1,
        }
      },

      /** AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE
       * OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
       * instance scope is what makes that true rather than aspirational:
       * the inner host closes when the outer instance deactivates, in
       * the same reverse unwind as every other resource. */
      nest: (nestopts?: HostOptions) => {
        if (!intransition) {
          fail('plugin_release_scope', 'nest called outside a lifecycle callback')
        }
        const inner = makehost(nestopts)
        e.scope.push(() => inner.close())
        e.inner = inner
        return inner
      },
    }
  }

  /** AUTO-TAGGING IS EXPLICIT (§4 rule 3). `declare('stripe', {tag:
   * '?'})` assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns
   * the assigned pair. Without `'?'`, a collision is an error.
   *
   * It needs a host because it must know what is already declared,
   * which is why it cannot live in the pure `ref` section — the
   * correction P1.7 made to §15.3. */
  function autotag(name: string): string {
    for (let n = 1; ; n++) {
      const cand = formatref(name, String(n))
      if (undefined === inst[cand]) return cand
    }
  }

  function declare(ref: string, spec?: { definition?: string, options?: any, order?: OrderBlock, pos?: number, tag?: string }): Live {
    if (spec && '?' === spec.tag) {
      ref = autotag(parseref(canonref(ref)).name)
    }
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
      bindings: [], exports: {}, provides: [],
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

  /** A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1) — it is a
   * dependency on something that can do the job, and which instance is
   * doing it is exactly the configuration detail a plugin must not care
   * about. A bare string is shorthand for `{name}`.
   *
   * A ref satisfies too, because a host that genuinely needs a specific
   * instance should not have to invent a capability for it. */
  function unmetof(e: Live): string[] {
    const req: any[] = (e.options && e.options.requires) || []
    const optional: string[] = (e.options && e.options.optional) || []

    return req
      .map((r: any) => ('string' === typeof r ? { name: r } : r) as Required)
      .filter((r) => !r.optional && -1 === optional.indexOf(r.name))
      .filter((r) => 0 === providersof(r).length)
      .map((r) => r.name)
  }

  function providersof(req: Required): Candidate[] {
    const cands: Candidate[] = []
    for (const ref of Object.keys(inst).sort()) {
      const t = inst[ref]
      if ('live' !== t.status) continue
      // A ref satisfies directly.
      if (ref === canonref(req.name)) {
        cands.push({ ref, pos: t.pos, provides: { name: req.name } })
        continue
      }
      for (const p of t.provides) {
        if (p.name === req.name) cands.push({ ref, pos: t.pos, provides: p })
      }
    }
    return resolvecapability(req, cands)
  }

  /** EAGER reconciliation: run to a fixed point rather than scheduling.
   *
   * Two directions, and both are the reason `pending` exists.
   * Activation is a STANDING REQUEST, not a one-shot event: a pending
   * instance whose requirement arrives activates without being asked
   * again, and a LIVE instance whose requirement is lost goes back to
   * pending — recursively, through its own consumers. */
  function reconcile(): void {
    let moved = true
    let rounds = 0
    while (moved) {
      moved = false
      if (1000 < ++rounds) break

      // Losses first, so a cascade settles in one pass rather than
      // alternating with re-activations.
      for (const r of Object.keys(inst).sort()) {
        const e = inst[r]
        if ('live' !== e.status) continue
        if (0 === unmetof(e).length) continue
        const policy = (e.options && e.options.policy) || 'static'
        if ('dynamic' === policy) continue   // said in writing it can cope
        try { run(e, 'deactivate', 'deactivate') } catch (err) { /* → failed below */ }
        unwind(e)
        e.status = 'pending'
        e.unmet = unmetof(e)
        moved = true
      }

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

  // --- points ------------------------------------------------------

  /** Live bindings on a point, in resolved order. Recomputed on any
   * change to the live set (§7) rather than cached at startup — the bug
   * a host discovers only when something deactivates in production. */
  function bound(point: string): Bound[] {
    const ranked = order(point)
    const out: Bound[] = []
    for (const ref of ranked) {
      const e = inst[ref]
      // The band is the INSTANCE's ordering block (§7), stamped by the
      // host. A plugin passing its own would be ranking itself above
      // the order its document declared.
      const band = (e.order && 'number' === typeof e.order.band) ? e.order.band : 0
      for (const b of e.bindings) {
        if (b.point === point) out.push({ ...b, band })
      }
    }
    return out
  }

  function emit(point: string, arg?: any): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if (spec.kind && 'hook' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a hook: ' + point, { point, kind: spec.kind })
    }
    return fanout(bound(point), (spec.mode || 'emit') as Mode, arg)
  }

  function call(point: string, ...args: any[]): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('chain' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a chain: ' + point, { point, kind: spec.kind })
    }
    const base = spec.base || ((x: any) => x)
    return compose(bound(point), base)(...args)
  }

  function provide(point: string, ...args: any[]): any {
    const spec = points[point]
    if (undefined === spec) fail('plugin_point_unknown', 'no such point: ' + point, { point })
    if ('provider' !== spec.kind) {
      fail('plugin_point_kind', 'point is not a provider: ' + point, { point, kind: spec.kind })
    }
    const pick = pickone(bound(point), spec)
    if (!pick.winner) return spec.default
    return pick.winner.fn(...args)
  }

  /** The losers are VISIBLE rather than silently ignored (§6.3). */
  function shadowed(point: string): string[] {
    const spec = points[point]
    if (undefined === spec) return []
    return pickone(bound(point), spec).shadowed
  }

  function exports(spec: string): any {
    const all: Exported[] = []
    for (const ref of Object.keys(inst).sort()) {
      const e = inst[ref]
      // Exports of a `loaded` (not live) instance are VISIBLE (§11).
      if ('declared' === e.status || 'failed' === e.status) continue
      for (const k of Object.keys(e.exports)) all.push({ ref, key: k, value: e.exports[k] })
    }
    return resolveexport(spec, all)
  }

  /** The live providers of a capability, best-first (§11.1). */
  function capability(name: string): string[] {
    const cands: Candidate[] = []
    for (const ref of Object.keys(inst).sort()) {
      const e = inst[ref]
      if ('live' !== e.status) continue
      for (const p of e.provides) {
        if (p.name === name) cands.push({ ref, pos: e.pos, provides: p })
      }
    }
    return resolvecapability({ name }, cands).map((c) => c.ref)
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
      // REFILL rather than REBIND. A definition's callbacks close over
      // the options map they were handed at `define`; replacing the
      // reference here would leave every binding reading the values the
      // first apply gave it, and a re-applied document would silently
      // do nothing. Clearing and refilling the same map is portable to
      // every language, unlike a getter or an interception hook — which
      // the §18 portability budget forbids anyway.
      refill(inst[ref].options, options)
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
    const previous = { ...e.options }
    refill(e.options, resolveoptions({
      ref: e.ref, shape: shapeof(e.ref), doc: {}, patch: merge(previous, patch),
    }))
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

  /** Empty the target and refill it, so callers holding the reference
   * see the new values. */
  function refill(target: any, source: any): void {
    for (const k of Object.keys(target)) delete target[k]
    for (const k of Object.keys(source || {})) target[k] = source[k]
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

  /** The same record §6.6 gives a plugin about itself, reachable from
   * outside for the corpus. A plugin asks via `inst.position(point)`. */
  function positionof(ref: string, point: string): any {
    const e = inst[canonref(ref)]
    if (!e) fail('plugin_not_loaded', 'no such instance: ' + ref, { ref })
    const ranked = order(point)
    const index = ranked.indexOf(e.ref)
    return {
      index, count: ranked.length,
      outermost: 0 === index,
      innermost: index === ranked.length - 1,
    }
  }

  const self = {
    catalog, list, instance, order, observable,
    trace: () => events.slice(),
    autotag, positionof,
    emit, call, provider: provide, shadowed, exports, capability,
    declare, load, activate, deactivate, unload, ready, apply, close,
    options: setoptions,
    define: (def: Definition) => catalog.add(def),
  }
  return self
}
