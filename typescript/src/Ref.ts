/* Identity: name+tag, written `name$tag` (§4).
 *
 * The four pure functions, and the whole of what `ref` pins. They are
 * the first thing a new port implements and the first corpus section it
 * passes. */

import { Ref, fail } from './Types'

/** §4: `^[a-zA-Z@][a-zA-Z0-9.~_\-/]*$`, max 1024. */
const NAME_RE = /^[a-zA-Z@][a-zA-Z0-9.~_\-\/]*$/
/** §4: `^[a-zA-Z0-9.~_-]+$`, max 1024, or empty.
 *
 * The asymmetry with a name is deliberate: a tag MAY start with a digit
 * because auto-tagging assigns integer tags (`stripe$1`), and a tag
 * admits neither `@` nor `/` because a name is a package specifier and
 * a tag is not. */
const TAG_RE = /^[a-zA-Z0-9.~_-]+$/

const MAX = 1024

export function checkname(name: string): boolean {
  if ('string' !== typeof name) return false
  if (0 === name.length || MAX < name.length) return false
  return NAME_RE.test(name)
}

export function checktag(tag: string): boolean {
  if ('string' !== typeof tag) return false
  // The empty tag is an ordinary tag (§4 rule 2). The single-instance
  // case writes no tag and never learns tags exist.
  if (0 === tag.length) return true
  if (MAX < tag.length) return false
  return TAG_RE.test(tag)
}

/** `name$tag` -> the pair. Canonicalizing: `stripe$` and `stripe` both
 * give tag ''. */
export function parseref(str: string): Ref {
  if ('string' !== typeof str) {
    fail('plugin_bad_name', 'ref must be a string')
  }

  // Split on the FIRST `$`. Nothing in the grammar decides this — `$` is
  // in neither character class — so the corpus is the arbiter (§4 rule
  // 5), and it picks the split that blames the part actually at fault:
  // `a$b$c` is a good name with a bad tag, not the reverse.
  const cut = str.indexOf('$')
  const name = -1 === cut ? str : str.substring(0, cut)
  const tag = -1 === cut ? '' : str.substring(cut + 1)

  if (!checkname(name)) {
    fail('plugin_bad_name', 'invalid plugin name: ' + name, { name })
  }
  if (!checktag(tag)) {
    fail('plugin_bad_tag', 'invalid plugin tag: ' + tag, { name, tag })
  }

  return { name, tag }
}

/** The pair -> `name$tag`. An empty tag NEVER writes the separator,
 * which is the half of canonicalization formatref owns: parse tolerates
 * `stripe$`, format never produces it, so a round trip is idempotent. */
export function formatref(name: string, tag?: string): string {
  const t = null == tag ? '' : tag
  if (!checkname(name)) {
    fail('plugin_bad_name', 'invalid plugin name: ' + name, { name })
  }
  if (!checktag(t)) {
    fail('plugin_bad_tag', 'invalid plugin tag: ' + t, { name, tag: t })
  }
  return '' === t ? name : name + '$' + t
}

/** The canonical spelling of a ref. §4 rule 5: ports must canonicalize
 * before comparison. */
export function canonref(str: string): string {
  const r = parseref(str)
  return formatref(r.name, r.tag)
}
