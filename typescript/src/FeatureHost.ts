/* The sdkgen bridge (§17.2, P3 item 2).
 *
 * THE DELIVERABLE IS A BRIDGE THAT RUNS AN UNMODIFIED SDKGEN FEATURE
 * CLASS AS A PLUGIN, proving the two vocabularies map — and leaving
 * whether sdkgen's generated code adopts the model as a separate,
 * sdkgen-side decision with its own cost across 23 template trees.
 *
 * A generated SDK is not natively a host. Wrapping one in `inst.host()`
 * directly would be a host-shaped object around a non-host, so the
 * INNER HOST IS THE BRIDGE, NOT THE SDK: it declares points for the
 * SDK's hook vocabulary and its `request` chain, and a feature's own
 * method names become its bindings.
 *
 * WHAT THE BRIDGE BUYS, IN ONE SENTENCE: sdkgen can activate a feature
 * and cannot deactivate one, because its transport wrap is an
 * irreversible assignment — `ctx.utility.fetcher = wrapped` — and its
 * hook methods are read off a fixed array. Both become bindings here,
 * and bindings come out. */

import { Definition } from './Catalog'
import { PointSpec } from './Host'

/** sdkgen's declared hook vocabulary (`main.kit.feature.&.hook` in
 * `model/sdkgen.aontu`).
 *
 * §17.2 says "13 hook points, named exactly as today". The model
 * declares ELEVEN; the three station's own feature adds — `PrePoint`,
 * `PreDone`, `PreUnexpected` — are declared by that feature rather than
 * by the core, because `hook: &:` admits any name. So the count depends
 * on which features are installed, which is why `featurepoints` takes
 * the extra names rather than this list pretending to be closed.
 * Recorded in doc/plan/handover.md rather than silently resolved. */
export const SDK_HOOKS = [
  'PostConstruct',
  'PostConstructEntity',
  'SetData',
  'GetData',
  'GetMatch',
  'PreTarget',
  'PreSpec',
  'PreRequest',
  'PreResponse',
  'PreResult',
  'PostOperation',
]

/** The hooks sdkgen-station's feature declares beyond the core set.
 * Named here so the bridge's default vocabulary covers the one feature
 * this repo's first consumer actually ships. */
export const STATION_HOOKS = ['PrePoint', 'PreDone', 'PreUnexpected']

/** The one chain point: the SDK's transport. Its base is
 * `utility.fetcher`, which is exactly what a wrapping feature captures
 * and replaces today. */
export const REQUEST_POINT = 'request'

/** Points for a bridge host: every hook name as a `hook` point, plus
 * `request` as a `chain` whose base is the SDK's own fetcher.
 *
 * `extra` carries the hook names a particular SDK's installed features
 * declare beyond the core vocabulary. */
export function featurepoints(
  fetcher: (...args: any[]) => any, extra?: string[]
): { [point: string]: PointSpec } {
  const points: { [point: string]: PointSpec } = {}
  const names = SDK_HOOKS
    .concat(STATION_HOOKS)
    .concat(extra || [])
  for (const h of names) {
    if (undefined === points[h]) { points[h] = { kind: 'hook' } }
  }
  points[REQUEST_POINT] = { kind: 'chain', base: fetcher }
  return points
}

/** The ctx an sdkgen feature's `init` expects.
 *
 * `utility.fetcher` is a GETTER/SETTER PAIR rather than a field, and
 * that is the whole trick: a feature that writes
 * `ctx.utility.fetcher = wrapped` is expressing a chain binding, and
 * the bridge records it as one instead of letting it overwrite the
 * slot. Reading it back returns the marker the feature should call,
 * which is `next` — so the feature's own `const inner = utility.fetcher`
 * still gives it something to call through to.
 *
 * This is the single place the irreversible assignment becomes
 * reversible; everything else about the feature is untouched. */
type Captured = {
  wrap?: (...args: any[]) => any
  inner: any
}

function makectx(base: any, captured: Captured, options: any): any {
  const utility: any = {}
  Object.defineProperty(utility, 'fetcher', {
    enumerable: true,
    get: () => captured.inner,
    set: (fn: any) => { captured.wrap = fn },
  })
  return { ...base, utility, options }
}

export type FeatureClass = {
  new(...args: any[]): any
}

/** Turn an sdkgen `Feature` class into a plugin definition, MECHANICALLY
 * (§17.2):
 *
 *  - `name` and `version` come off the instance, as today;
 *  - `init(ctx, options)` splits: it runs in `define`, where reading
 *    options and declaring bindings belong;
 *  - a method named after a hook point IS a binding to that point —
 *    "a feature's method names are its bindings";
 *  - an assignment to `ctx.utility.fetcher` becomes a `request` chain
 *    binding rather than an irreversible overwrite.
 *
 * The feature class is not modified, subclassed or inspected beyond its
 * own public surface. That is the claim being proved. */
export function featuredefinition(
  name: string, Feature: FeatureClass, hooks?: string[]
): Definition {
  const hooknames = SDK_HOOKS.concat(STATION_HOOKS).concat(hooks || [])

  return {
    name,

    define: (inst: any) => {
      const feature: any = new (Feature as any)()
      const captured: Captured = { inner: undefined }

      // `inner` is what the feature reads back from `utility.fetcher`.
      // In a chain the value to call through to is `next`, which is not
      // known until the binding runs — so the feature is handed a
      // trampoline that forwards to whatever `next` is at call time.
      let current: any = null
      captured.inner = (...args: any[]) =>
        null == current ? undefined : current(...args)

      const ctx = makectx({ client: inst, feature }, captured, inst.options)

      // The SDK calls `init(ctx, options)`; so do we, unchanged.
      if ('function' === typeof feature.init) {
        feature.init(ctx, inst.options)
      }

      // A method named after a hook point IS a binding to it.
      for (const h of hooknames) {
        if ('function' !== typeof feature[h]) { continue }
        inst.bind(h, (...args: any[]) => feature[h](...args))
      }

      // ...and the transport wrap, if the feature took one, is a chain
      // binding. THIS IS THE REVERSIBILITY: sdkgen assigns the slot and
      // can never put it back; a binding comes out when the instance
      // deactivates, with no cooperation from the feature.
      if ('function' === typeof captured.wrap) {
        inst.bind(REQUEST_POINT, (next: any, ...args: any[]) => {
          current = next
          return (captured.wrap as any)(...args)
        })
      }

      inst.export('feature', feature)
      if (null != feature.version) {
        inst.export('version', feature.version)
      }
    },
  }
}
