/* Versions and ranges (§11.2).
 *
 * TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a
 * concrete version. A requirement declares `range`. A requirement is
 * satisfied when the names match, the `match` passes, and:
 *
 *   the provider's `version` falls inside the requirement's `range`.
 *
 * That is the whole rule. There is no third field and no second
 * comparison — an earlier draft added a provider-side `compat` range,
 * which left three values and no statement of how they combine, and
 * three defensible readings of one declaration is worse than the
 * ambiguity it was introduced to fix. */

'use strict'

const { fail } = require('./types')

const VERSION_RE = /^(\d+)(?:\.(\d+))?(?:\.(\d+))?$/

/** Two forms and no more (§11.2):
 *
 *   '2.1'    >= 2.1.0 and < 3.0.0
 *   '~2.1'   >= 2.1.0 and < 2.2.0
 */
function parserange(range) {
  if ('string' !== typeof range || 0 === range.length) {
    fail('plugin_bad_range', 'invalid range: ' + range, { range })
  }

  const tilde = range.startsWith('~')
  const body = tilde ? range.substring(1) : range
  const m = VERSION_RE.exec(body)
  if (!m) fail('plugin_bad_range', 'invalid range: ' + range, { range })

  const major = Number(m[1])
  const minor = undefined === m[2] ? 0 : Number(m[2])
  const patch = undefined === m[3] ? 0 : Number(m[3])

  const lo = [major, minor, patch]
  const hi = tilde ? [major, minor + 1, 0] : [major + 1, 0, 0]
  return { lo, hi }
}

function parseversion(version) {
  if ('string' !== typeof version) {
    fail('plugin_bad_range', 'invalid version: ' + version, { version })
  }
  const m = VERSION_RE.exec(version)
  if (!m) fail('plugin_bad_range', 'invalid version: ' + version, { version })
  return [
    Number(m[1]),
    undefined === m[2] ? 0 : Number(m[2]),
    undefined === m[3] ? 0 : Number(m[3]),
  ]
}

/** The one satisfaction predicate: lo <= version < hi. */
function satisfies(version, range) {
  const v = parseversion(version)
  const r = parserange(range)
  return 0 <= cmp(v, r.lo) && 0 > cmp(v, r.hi)
}

/** satisfies for the internal callers that treat an unparseable version
 * or range as "does not satisfy" — Capability and Graph, both of which
 * run over data the corpus has already admitted. */
function satisfiesq(version, range) {
  try { return satisfies(version, range) }
  catch (err) { return false }
}

function cmp(a, b) {
  for (let i = 0; i < 3; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1
  }
  return 0
}

module.exports = { parserange, parseversion, satisfies, satisfiesq, cmp }
