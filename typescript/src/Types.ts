/* Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else. */

/** The two halves of an identity (§4). `tag` is '' when absent — never
 * null and never missing, because a port returning three shapes for two
 * states makes every downstream comparison a special case. */
export type Ref = { name: string, tag: string }

/** §5.1's seven statuses, and no more. A port that adds an eighth is
 * diverging. `loading` and `closing` are observable only from inside a
 * callback or from another thread. */
export type Status =
  'declared' | 'loaded' | 'pending' | 'live' | 'failed' | 'loading' | 'closing'

/** A normalized instance entry. Option data is NOT merged here — see
 * `optionlayers`. */
export type Instance = {
  pos: number
  active: boolean
  start: 'eager' | 'lazy'
  order?: OrderBlock
  /** Levels 3-6 that are present, IN LADDER ORDER (§9.3).
   *
   * Normalization does not merge these, and cannot: §9.4 makes merge
   * behaviour a property of the definition's option shape, which
   * normalization has never seen. Flattening them here would make
   * `$MERGE: append` unimplementable at load time, because the layers
   * it must concatenate would already be collapsed. */
  optionlayers: any[]
}

/** §4.4 of DOCS.md — `band` rather than a nested `order`, because
 * `order.order` needs explaining every time it is read. */
export type OrderBlock = { before?: string, after?: string, band?: number }

export type Normalized = {
  instance: { [ref: string]: Instance }
  order: string[]
  default: { [name: string]: any }
}

/** Every error carries a §12 code. Ports compare by code and never by
 * message: wording is a port's own business, and pinning it would make
 * every translation a corpus change. */
export class PluginError extends Error {
  code: string
  details: { [k: string]: any }
  constructor(code: string, message: string, details?: { [k: string]: any }) {
    super(message)
    this.name = 'PluginError'
    this.code = code
    this.details = details || {}
  }
}

export function fail(code: string, message: string, details?: any): never {
  throw new PluginError(code, message, details)
}
