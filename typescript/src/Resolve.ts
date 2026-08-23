/* Dynamic resolution (§10.2) — name to candidate module ids.
 *
 * PURE. It returns the ids a host WOULD try, in order; it does not load
 * anything. That separation is what lets the corpus pin resolution in
 * every language including those with no dynamic loading at all, and it
 * is why §15.4 puts real module loading in per-port integration tests
 * rather than here.
 *
 * The corpus `resolve` section arrives with P2. */

export type Source =
  | { kind: 'module', prefix?: string[] }
  | { kind: 'path', dir: string }

export function resolvecandidates(name: string, sources?: Source[]): string[] {
  const out: string[] = []
  const list = sources && 0 < sources.length ? sources : DEFAULT_SOURCES

  for (const src of list) {
    if ('module' === src.kind) {
      const prefixes = src.prefix && 0 < src.prefix.length ? src.prefix : ['']
      for (const p of prefixes) {
        const id = p + name
        if (-1 === out.indexOf(id)) out.push(id)
      }
    }
    else if ('path' === src.kind) {
      const id = src.dir.replace(/\/+$/, '') + '/' + name
      if (-1 === out.indexOf(id)) out.push(id)
    }
  }

  return out
}

const DEFAULT_SOURCES: Source[] = [
  { kind: 'module', prefix: ['@voxgig/plugin-', 'voxgig-plugin-', 'plugin-', ''] },
]
