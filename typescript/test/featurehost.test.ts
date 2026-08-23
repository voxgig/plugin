// RUN: npm test
//
// P3 item 2 (§17.2): the bridge runs an UNMODIFIED sdkgen feature class
// as a plugin.
//
// The feature classes below are written the way sdkgen generates them —
// `init(ctx, options)`, hook methods named after hook points, and a
// transport wrap done by assigning `ctx.utility.fetcher`. Nothing in
// them knows about plugin. That is the claim: the vocabularies map, and
// the mapping is mechanical.
//
// P3's exit names the property that makes the bridge worth having: the
// bridge "runs RetryFeature unmodified, AND DEACTIVATES IT — which
// sdkgen alone cannot do", because sdkgen's wrap is an irreversible
// assignment to a slot.

import { describe, test } from 'node:test'
import { deepStrictEqual, equal, ok, throws } from 'node:assert'

import { makehost, makecatalog } from '../src/index'
import {
  REQUEST_POINT, SDK_HOOKS, featuredefinition, featurepoints,
} from '../src/FeatureHost'

// An sdkgen-shaped feature that WRAPS the transport, exactly as
// RetryFeature does: capture the current fetcher, install a replacement
// that calls through it.
class RetryFeature {
  name = 'retry'
  version = '0.0.1'
  inner: any = null
  attempts = 0
  retries = 2

  init(ctx: any, options: any) {
    this.retries = options?.retries ?? 2
    const inner = ctx.utility.fetcher
    this.inner = inner
    ctx.utility.fetcher = (...args: any[]) => {
      this.attempts++
      return inner(...args)
    }
  }

  PreRequest(ctx: any) {
    ctx.seen = (ctx.seen || []).concat(['retry'])
  }
}

// ...and one that only hooks, taking no transport wrap at all.
class LogFeature {
  name = 'log'
  version = '0.0.1'
  lines: string[] = []

  init(_ctx: any, options: any) {
    this.lines.push('init:' + (options?.level ?? 'info'))
  }

  PreRequest(ctx: any) {
    ctx.seen = (ctx.seen || []).concat(['log'])
  }

  PostOperation(_ctx: any) {
    this.lines.push('done')
  }
}

// An sdkgen-shaped feature that serves a `__replace__` seam: one
// method, named for the seam, returning the replacement.
class CodecFeature {
  name = 'codec'
  Encode(v: any) { return 'encoded:' + v }
}

// ...one that reads the SDK's own ctx, which is not the bridge's to
// invent.
class CtxFeature {
  name = 'ctxread'
  sawclient: any = null
  init(ctx: any) {
    this.sawclient = ctx.client
    ctx.utility.log('init')
    const inner = ctx.utility.fetcher
    ctx.utility.fetcher = (...args: any[]) => inner(...args)
  }
}

// ...and one carrying the lifecycle methods §17.2 expects an adopting
// sdkgen to add, which today's generated features do not have.
class PhasedFeature {
  name = 'phased'
  log: string[] = []
  init() { this.log.push('init') }
  activate() { this.log.push('activate') }
  deactivate() { this.log.push('deactivate') }
  close() { this.log.push('close') }
}

// ...and one whose `activate` raises, so the instance lands in `failed`
// while still holding whatever `init` opened.
const BROKEN: BrokenFeature[] = []
class BrokenFeature {
  name = 'broken'
  log: string[] = []
  constructor() { BROKEN.push(this) }
  init() { this.log.push('init') }
  activate() { this.log.push('activate'); throw new Error('activate failed') }
  close() { this.log.push('close') }
}

function bridge(defs: { name: string, cls: any }[], opts?: any) {
  const base = (n: number) => 'base:' + n
  const catalog = makecatalog(
    defs.map((d) => featuredefinition(d.name, d.cls, opts)))
  return makehost({ catalog, points: featurepoints(base, opts) })
}

describe('featurehost-bridge', () => {

  test('an unmodified feature class loads and activates', () => {
    const host = bridge([{ name: 'retry', cls: RetryFeature }])
    host.ready('retry$a')

    equal('live', host.list()['retry$a'])

    // Its own object is reachable, unmodified and un-subclassed.
    const feature: any = host.exports('retry$a/feature')
    ok(feature instanceof RetryFeature)
    equal('0.0.1', host.exports('retry$a/version'))
  })

  test('a hook method IS a binding, and fires on emit', () => {
    const host = bridge([
      { name: 'retry', cls: RetryFeature },
      { name: 'log', cls: LogFeature },
    ])
    host.ready('retry$a')
    host.ready('log$a')

    const ctx: any = {}
    host.emit('PreRequest', ctx)
    // Both features' PreRequest ran, in resolved order.
    deepStrictEqual(ctx.seen, ['retry', 'log'])

    // A hook only one of them declares reaches only that one.
    host.emit('PostOperation', {})
    const log: any = host.exports('log$a/feature')
    deepStrictEqual(log.lines, ['init:info', 'done'])
  })

  test('the transport wrap becomes a chain binding, and calls through', () => {
    const host = bridge([{ name: 'retry', cls: RetryFeature }])
    host.ready('retry$a')

    // The chain composes the feature's wrap over the base fetcher, and
    // the feature's own `const inner = utility.fetcher` still reaches
    // the thing below it.
    equal('base:7', host.call(REQUEST_POINT, 7))

    const feature: any = host.exports('retry$a/feature')
    equal(1, feature.attempts)
  })

  test('THE POINT: it deactivates, which sdkgen alone cannot do', () => {
    const host = bridge([{ name: 'retry', cls: RetryFeature }])
    host.ready('retry$a')

    const feature: any = host.exports('retry$a/feature')
    host.call(REQUEST_POINT, 1)
    host.emit('PreRequest', {})
    equal(1, feature.attempts)

    host.deactivate('retry$a')
    equal('loaded', host.list()['retry$a'])

    // The wrap is GONE from the chain - the base answers directly - and
    // the hook binding is gone with it. sdkgen assigns
    // `ctx.utility.fetcher` and has nowhere to put the old value back;
    // a binding just comes out.
    equal('base:2', host.call(REQUEST_POINT, 2))
    equal(1, feature.attempts, 'the wrap must not run after deactivate')

    const ctx: any = {}
    host.emit('PreRequest', ctx)
    equal(undefined, ctx.seen, 'the hook binding must be gone too')
  })

  test('and reactivates, with the wrap back in the chain', () => {
    const host = bridge([{ name: 'retry', cls: RetryFeature }])
    host.ready('retry$a')
    host.deactivate('retry$a')
    host.activate('retry$a')

    equal('live', host.list()['retry$a'])
    equal('base:3', host.call(REQUEST_POINT, 3))

    const ctx: any = {}
    host.emit('PreRequest', ctx)
    deepStrictEqual(ctx.seen, ['retry'])
  })

  test('options reach init in the SDK s own spelling', () => {
    const host = bridge([{ name: 'retry', cls: RetryFeature }])
    host.declare('retry$a', { options: { retries: 5 } })
    host.ready('retry$a')

    const feature: any = host.exports('retry$a/feature')
    equal(5, feature.retries)
  })

  test('the declared hook vocabulary is the SDK s, named as today', () => {
    // §17.2: "13 hook points, named exactly as today". The core model
    // declares eleven; the rest come from the features installed, which
    // is why featurepoints takes them rather than hard-coding a count.
    equal(11, SDK_HOOKS.length)
    for (const h of ['PostConstruct', 'PreRequest', 'PreResponse', 'PostOperation']) {
      ok(-1 !== SDK_HOOKS.indexOf(h), h + ' is part of the vocabulary')
    }

    const points = featurepoints((n: number) => n, { hooks: ['Custom'] })
    equal('chain', points[REQUEST_POINT].kind)
    equal('hook', points['PreRequest'].kind)
    equal('hook', points['Custom'].kind, 'an SDK s own extra hook is declarable')
  })

  // ---- what review found the first version got wrong ----------------

  test('a repeated hook name binds ONCE, not twice', () => {
    // `hooks` is "what this SDK's features declare", and a feature may
    // well declare a core one. Concatenating without dedup bound the
    // same method twice, so one emit ran it twice.
    const host = bridge([{ name: 'log', cls: LogFeature }],
      { hooks: ['PreRequest', 'PreRequest'] })
    host.ready('log$a')

    const ctx: any = {}
    host.emit('PreRequest', ctx)
    deepStrictEqual(ctx.seen, ['log'], 'the method must fire exactly once')
  })

  test('a replacement seam is a PROVIDER point, not a hook', () => {
    // §17.2: "`provider` points for the seams `__replace__` currently
    // serves". At most one wins, the losers are visible, the host keeps
    // a default - which is what a replacement means and what a chain
    // cannot express.
    const points = featurepoints((n: number) => n, { replace: ['Encode'] })
    equal('provider', points['Encode'].kind)

    const host = bridge([{ name: 'codec', cls: CodecFeature }],
      { replace: ['Encode'] })
    host.ready('codec$a')
    equal('encoded:x', host.provider('Encode', 'x'))

    // ...and it comes out, which is the point of the whole exercise.
    host.deactivate('codec$a')
    equal(undefined, host.provider('Encode', 'x'))
  })

  test('the SDK s real ctx reaches init, not a synthetic stub', () => {
    // A feature reading `ctx.client` or any `ctx.utility` member other
    // than `fetcher` got the plugin instance and an otherwise empty
    // object. Both are the SDK's to supply.
    const client = { id: 'real-client' }
    const log: string[] = []
    const host = bridge([{ name: 'ctxread', cls: CtxFeature }],
      { ctx: { client, utility: { log: (m: string) => log.push(m) } } })
    host.ready('ctxread$a')

    const feature: any = host.exports('ctxread$a/feature')
    equal(client, feature.sawclient, 'the SDK s own client, not the instance')
    deepStrictEqual(log, ['init'], 'the SDK s own utility survives the trap')
    // ...and the fetcher trap still works alongside it.
    equal('base:4', host.call(REQUEST_POINT, 4))
  })

  test('a feature name that disagrees with its definition is refused', () => {
    // Configuration addressed by the SDK's feature name could not
    // resolve the definition, and the exported object would report a
    // third identity. Loud, because the failure it prevents is silent.
    const host = bridge([{ name: 'mislabelled', cls: RetryFeature }])
    throws(() => host.ready('mislabelled$a'), /plugin_definition_name/)
  })

  test('a feature s own activate/deactivate are wired, in phase', () => {
    // §17.2 splits `init` into define (declare bindings) and activate
    // (capture). An unmodified feature has no such split - which is why
    // the bridge's claim is about BINDINGS - but one that grows the
    // methods gets them called where the model puts them.
    const host = bridge([{ name: 'phased', cls: PhasedFeature }])
    host.ready('phased$a')
    const feature: any = host.exports('phased$a/feature')
    deepStrictEqual(feature.log, ['init', 'activate'])

    host.deactivate('phased$a')
    deepStrictEqual(feature.log, ['init', 'activate', 'deactivate'])

    host.activate('phased$a')
    deepStrictEqual(feature.log, ['init', 'activate', 'deactivate', 'activate'])

    host.unload('phased$a')
    deepStrictEqual(feature.log,
      ['init', 'activate', 'deactivate', 'activate', 'deactivate', 'close'])
  })

  test('a FAILED instance still gets its feature s close on unload', () => {
    // §5.2: `unload` is the only exit from `failed`, and it runs
    // `close`. The bridge read the feature back through `exports`,
    // which §11 hides for a failed instance — so `close` saw undefined
    // and did nothing, in exactly the case where a feature holding a
    // connection most needs it. The feature lives in the instance's own
    // state, which survives every status.
    const host = bridge([{ name: 'broken', cls: BrokenFeature }])
    throws(() => host.ready('broken$a'), /activate failed/)
    equal('failed', host.list()['broken$a'])

    // The export is gone, as §11 says it must be...
    equal(undefined, host.exports('broken$a/feature'))

    // ...and `close` still reaches the feature. THE FEATURE'S OWN LOG
    // IS THE ASSERTION: reading it back through `exports` leaves
    // `close` absent here while every other expectation in this file
    // stays green.
    const feature = BROKEN[BROKEN.length - 1]
    deepStrictEqual(feature.log, ['init', 'activate'])
    host.unload('broken$a')
    deepStrictEqual(feature.log, ['init', 'activate', 'close'])
    deepStrictEqual(host.list(), {})
  })

  test('sequential and nested calls each reach their own next', () => {
    // The shared `current` slot is correct for every synchronous path:
    // the binding sets it immediately before the wrap runs. The known
    // limit is an AWAITING wrap overtaken by a second request, which
    // needs a per-invocation channel the feature would have to be
    // modified to accept - stated in FeatureHost.ts rather than
    // pretended away.
    const host = bridge([
      { name: 'retry', cls: RetryFeature },
      { name: 'log', cls: LogFeature },
    ])
    host.ready('retry$a')
    host.ready('log$a')

    equal('base:1', host.call(REQUEST_POINT, 1))
    equal('base:2', host.call(REQUEST_POINT, 2))
    const feature: any = host.exports('retry$a/feature')
    equal(2, feature.attempts)

    // ...and the chain recomposes under it between calls.
    host.deactivate('retry$a')
    equal('base:3', host.call(REQUEST_POINT, 3))
    equal(2, feature.attempts)
  })
})
