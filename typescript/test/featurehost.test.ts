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
import { deepStrictEqual, equal, ok } from 'node:assert'

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

function bridge(defs: { name: string, cls: any }[]) {
  const base = (n: number) => 'base:' + n
  const catalog = makecatalog(
    defs.map((d) => featuredefinition(d.name, d.cls)))
  return makehost({ catalog, points: featurepoints(base) })
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

    const points = featurepoints((n: number) => n, ['Custom'])
    equal('chain', points[REQUEST_POINT].kind)
    equal('hook', points['PreRequest'].kind)
    equal('hook', points['Custom'].kind, 'an SDK s own extra hook is declarable')
  })
})
