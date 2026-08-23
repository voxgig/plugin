/* Environment overrides (§9.5) — level 7 of the ladder.
 *
 * `VOXGIG_PLUGIN_<REF>_<PATH>` sets one option; `VOXGIG_PLUGIN_ACTIVE`
 * and `VOXGIG_PLUGIN_INACTIVE` bar or admit whole instances, and
 * INACTIVE has the final word.
 *
 * The corpus `env` section arrives with P2; this is the designed
 * behaviour, written now so the canonical surface is complete rather
 * than five names short. */

import { fail } from './Types'
import { canonref, parseref } from './Ref'

const PREFIX = 'VOXGIG_PLUGIN_'

export type EnvResult = {
  options: { [ref: string]: any }
  active: string[]
  inactive: string[]
}

export function applyenv(env: { [k: string]: string }, reserved?: string[]): EnvResult {
  const out: EnvResult = { options: {}, active: [], inactive: [] }
  const bar = reserved || []

  for (const key of Object.keys(env || {}).sort()) {
    if (!key.startsWith(PREFIX)) continue
    const rest = key.substring(PREFIX.length)

    if ('ACTIVE' === rest || 'INACTIVE' === rest) {
      const refs = String(env[key]).split(',').map((s) => s.trim()).filter((s) => 0 < s.length)
      for (const r of refs) {
        const c = canonref(r)
        // The reservation covers EVERY input layer, not just documents
        // (§9.1). VOXGIG_PLUGIN_INACTIVE=station is easier to set than
        // editing a config file, and INACTIVE has the final word — so
        // stating the guard for documents alone would leave the one
        // lever this mechanism exists to deny wide open.
        checkreserved(c, bar)
        if ('ACTIVE' === rest) out.active.push(c)
        else out.inactive.push(c)
      }
      continue
    }

    // <REF>_<PATH>. The ref is everything before the first path segment
    // that is not part of a ref; refs are lowercased with `__` for `$`
    // so that a shell can express them.
    const cut = rest.indexOf('__')
    if (-1 === cut) {
      fail('plugin_env_ambiguous', 'cannot split ref from path: ' + key, { key })
    }
    const ref = canonref(rest.substring(0, cut).toLowerCase().replace(/_/g, '-'))
    checkreserved(ref, bar)
    const path = rest.substring(cut + 2).toLowerCase().split('__')

    let node = out.options[ref] || (out.options[ref] = {})
    for (let i = 0; i < path.length - 1; i++) {
      node = node[path[i]] || (node[path[i]] = {})
    }
    node[path[path.length - 1]] = coerce(env[key])
  }

  return out
}

function checkreserved(ref: string, reserved: string[]): void {
  if (0 === reserved.length) return
  if (-1 !== reserved.indexOf(parseref(ref).name)) {
    fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref, { ref })
  }
}

function coerce(v: string): any {
  if ('true' === v) return true
  if ('false' === v) return false
  if ('' !== v && !isNaN(Number(v))) return Number(v)
  return v
}
