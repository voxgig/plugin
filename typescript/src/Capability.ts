/* Capabilities (§11.1).
 *
 * A DEPENDENCY IS ON A CAPABILITY, NOT ON A REF — because it is a
 * dependency on something that can do the job, and which instance is
 * doing it is exactly the configuration detail a plugin must not care
 * about.
 *
 * But A BINDING IS TO AN INSTANCE, not to a capability, which is what
 * decides behaviour when the bound provider leaves while another match
 * remains. */

import { satisfies } from './Version'

export type Provided = {
  name: string
  version?: string
  priority?: number
  attrs?: { [k: string]: any }
}

export type Required = {
  name: string
  range?: string
  match?: { [k: string]: any }
  optional?: boolean
  /** §11.3: `static` restarts the consumer when its SELECTED provider
   * leaves, even though another still matches; `dynamic` says in
   * writing that it can survive the swap. Static is the default because
   * most plugins cannot, and the cost of wrongly assuming they can is a
   * live instance holding a dead reference. */
  policy?: 'static' | 'dynamic'
}

export type Candidate = {
  ref: string
  pos: number
  provides: Provided
}

/** Rank the matching live providers and return them best-first:
 * highest `version`, then LOWEST `priority` (default 0), then
 * declaration position `pos` ascending.
 *
 * `priority` is a field on the capability rather than §7's `order`
 * band, because bands live on POINT BINDINGS: a provider may have
 * several bindings with different bands, or none at all, so a rank
 * reaching for one would be undefined in the common case.
 *
 * Without a total rank, "any provider satisfies" is true of the GRAPH
 * and useless to the PLUGIN — two ports could bind different `store`
 * instances, both resolve green, and behave differently, which is
 * precisely the divergence a shared corpus exists to catch. */
export function resolvecapability(req: Required, candidates: Candidate[]): Candidate[] {
  const hits = candidates.filter((c) => matches(req, c.provides))
  hits.sort((a, b) => {
    const av = a.provides.version, bv = b.provides.version
    if (av !== bv) {
      if (undefined === av) return 1
      if (undefined === bv) return -1
      const c = compare(bv, av)      // highest version FIRST
      if (0 !== c) return c
    }
    const ap = a.provides.priority || 0
    const bp = b.provides.priority || 0
    if (ap !== bp) return ap - bp    // lowest priority first
    return a.pos - b.pos
  })
  return hits
}

export function matches(req: Required, prov: Provided): boolean {
  if (req.name !== prov.name) return false

  if (undefined !== req.range) {
    if (undefined === prov.version) return false
    if (!satisfies(prov.version, req.range)) return false
  }

  // `match` is checked against the provider's `attrs`, key by key. A
  // key the provider does not carry is a miss, not a pass: a
  // requirement asking for `transactional: true` must not be satisfied
  // by a provider that never said.
  if (undefined !== req.match) {
    const attrs = prov.attrs || {}
    for (const k of Object.keys(req.match)) {
      if (attrs[k] !== req.match[k]) return false
    }
  }

  return true
}

function compare(a: string, b: string): number {
  const pa = a.split('.').map(Number)
  const pb = b.split('.').map(Number)
  for (let i = 0; i < 3; i++) {
    const x = pa[i] || 0, y = pb[i] || 0
    if (x !== y) return x < y ? -1 : 1
  }
  return 0
}
