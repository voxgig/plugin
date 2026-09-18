
export type Ref = { name: string, tag: string }

export type Status =
  'declared' | 'loaded' | 'pending' | 'live' | 'failed' | 'loading' | 'closing'

/** A normalized instance entry. Option data is NOT merged here — see
 * `optionlayers`. */
export type Instance = {
  pos: number
  active: boolean
  start: 'eager' | 'lazy'
  order?: OrderBlock
  optionlayers: any[]
}

export type OrderRef = string | string[]

export type OrderSpec = OrderRef | null

export type OrderBlock = { before?: OrderSpec, after?: OrderSpec, band?: number }

export type Normalized = {
  instance: { [ref: string]: Instance }
  order: string[]
  default: { [name: string]: any }
}

export const DETAIL_ORDER = [
  'host', 'ref', 'name', 'tag', 'point', 'key', 'capability',
  'range', 'version', 'match', 'candidates', 'cycle', 'holders',
  'refs', 'path', 'cause',
]

/** `plugin/<code>: <text> [<key>=<value> …]`
 *
 * Values render as COMPACT JSON, so a value containing a space or a
 * bracket cannot break the parse, and a list renders as a JSON array.
 * The bracket is absent entirely when no field applies. */
export function formaterror(code: string, text: string, details?: { [k: string]: any }): string {
  const d = details || {}
  const parts: string[] = []
  for (const k of DETAIL_ORDER) {
    if (undefined === d[k]) continue
    parts.push(k + '=' + JSON.stringify(d[k]))
  }
  const tail = 0 === parts.length ? '' : ' [' + parts.join(' ') + ']'
  return 'plugin/' + code + ': ' + text + tail
}

export class PluginError extends Error {
  code: string
  text: string
  details: { [k: string]: any }
  constructor(code: string, text: string, details?: { [k: string]: any }) {
    super(formaterror(code, text, details))
    this.name = 'PluginError'
    this.code = code
    this.text = text
    this.details = details || {}
  }
}

export function fail(code: string, text: string, details?: any): never {
  throw new PluginError(code, text, details)
}
