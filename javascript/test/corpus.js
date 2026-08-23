/* The corpus runner.
 *
 * Reads spec/plugin.json — the COMMITTED artifact, not the aontu source
 * — exactly as every other port's runner does. No port needs a Node
 * toolchain to run its tests, and this one does not get a private door
 * into the source either.
 *
 * A group name selects the subject. That is the whole dispatch, and it
 * is deliberately dumb: a runner that inferred the subject from the
 * entry's shape would silently run the wrong function when an entry was
 * mistyped. */

'use strict'

const Fs = require('node:fs')
const Path = require('node:path')

const { codeof } = require('../src/index')

const SPEC = Path.join(__dirname, '..', '..', 'spec', 'plugin.json')

function corpus() {
  return JSON.parse(Fs.readFileSync(SPEC, 'utf8'))
}

function section(name) {
  const spec = corpus()
  const sec = spec.primary && spec.primary[name]
  if (null == sec) throw new Error('no such corpus section: ' + name)
  const out = {}
  for (const g of Object.keys(sec)) {
    if ('DEF' === g) continue
    if (sec[g] && Array.isArray(sec[g].set)) out[g] = sec[g].set
  }
  return out
}

/** A stable label, so a failure names the entry rather than an index. */
function label(group, i, e) {
  return e.id ? e.id : group + '#' + i
}

/** Deep equality over spec values. Key order never matters; list order
 * always does. */
function equal(a, b) {
  if (a === b) return true
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false
    for (let i = 0; i < a.length; i++) if (!equal(a[i], b[i])) return false
    return true
  }
  if (isMap(a) && isMap(b)) {
    const ka = Object.keys(a).sort()
    const kb = Object.keys(b).sort()
    if (ka.length !== kb.length) return false
    for (let i = 0; i < ka.length; i++) if (ka[i] !== kb[i]) return false
    for (const k of ka) if (!equal(a[k], b[k])) return false
    return true
  }
  return false
}

/** Partial match: every key the expectation names must agree, and keys
 * it does not name are ignored. `__EXISTS__` asserts presence without
 * pinning a value; `/re/` matches a string as a regular expression. */
function matches(expect, actual) {
  if ('__EXISTS__' === expect) return undefined !== actual
  if ('__UNDEF__' === expect) return undefined === actual
  if ('__NULL__' === expect) return null === actual

  if ('string' === typeof expect && 2 < expect.length &&
      expect.startsWith('/') && expect.endsWith('/')) {
    if ('string' !== typeof actual) return false
    return new RegExp(expect.substring(1, expect.length - 1)).test(actual)
  }

  if (Array.isArray(expect)) {
    if (!Array.isArray(actual) || expect.length !== actual.length) return false
    for (let i = 0; i < expect.length; i++) if (!matches(expect[i], actual[i])) return false
    return true
  }

  if (isMap(expect)) {
    if (!isMap(actual)) return false
    for (const k of Object.keys(expect)) if (!matches(expect[k], actual[k])) return false
    return true
  }

  return expect === actual
}

function isMap(v) {
  return null != v && 'object' === typeof v && !Array.isArray(v)
}

/** Run one entry against a subject and report the disagreement, if any.
 *
 * The three combinations the spec format allows are enforced here as
 * well as at build time, because a runner that quietly accepted `err`
 * beside `out` would let a contradictory entry pass. */
function check(e, subject) {
  if (undefined !== e.err && undefined !== e.out) {
    return 'entry has both err and out'
  }

  let value
  let raised = null
  try {
    value = subject(e)
  }
  catch (err) {
    raised = err
  }

  if (undefined !== e.err) {
    if (null == raised) return 'expected a raise, got: ' + JSON.stringify(value)
    if (true !== e.err) {
      // Errors compare by CODE (§12). Message wording is a port's own
      // business, and pinning it would make every translation a corpus
      // change.
      if (codeof(raised) !== e.err) {
        return 'expected code ' + e.err + ', got ' + codeof(raised) +
          ' (' + raised.message + ')'
      }
    }
    if (undefined !== e.match) {
      const got = { err: { code: codeof(raised), message: raised.message, name: raised.name } }
      if (!matches(e.match, got)) {
        return 'error did not match ' + JSON.stringify(e.match) + ', got ' + JSON.stringify(got)
      }
    }
    return null
  }

  if (null != raised) {
    return 'unexpected raise: ' + codeof(raised) + ' ' + raised.message
  }

  if (undefined !== e.out) {
    if (!equal(e.out, value)) {
      return 'expected ' + JSON.stringify(e.out) + ', got ' + JSON.stringify(value)
    }
  }

  if (undefined !== e.match) {
    if (!matches(e.match, { in: e.in, out: value })) {
      return 'did not match ' + JSON.stringify(e.match) + ', got out=' + JSON.stringify(value)
    }
  }

  if (undefined === e.out && undefined === e.match) {
    return 'entry asserts nothing'
  }

  return null
}

module.exports = { corpus, section, label, equal, matches, check }
