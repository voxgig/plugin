/* Prove the corpus runs under voxgig/omni's runner, unmodified.
 *
 * `spec/plugin.json` is written in omni's spec format — `primary`, a
 * `set` per group, and omni's nine entry fields — but every port still
 * ships a HAND-WRITTEN runner for it, twenty-three copies of one
 * algorithm. Design §15 says "every port runs it through
 * voxgig/omni"; docs/ADR.md ADR-3 records why that is not yet true and
 * what it would take.
 *
 * This is the check that keeps the claim honest in the meantime. It
 * loads the committed corpus with omni's own runner and drives the
 * javascript port through all nineteen sections. A corpus change that
 * puts an entry outside omni's format — a field omni does not define,
 * `err` beside `out`, an empty `set` — fails here rather than being
 * found whenever the migration is attempted.
 *
 * TWO FLAGS ARE LOAD-BEARING, and both are stated rather than defaulted:
 *
 *   null: false — omni rewrites every JSON null to "__NULL__" by
 *   default, INCLUDING nulls inside `in`. `point/bail#null-declines`
 *   asserts that an authored null IS a value and declines in bail mode,
 *   so the driver must receive a real null. plugin's corpus is written
 *   in literal nulls throughout; omni's own §5 names this exact case.
 *
 *   errify — plugin's errors compare by CODE (§12), and omni's default
 *   error base carries only {name, message}. The provider hook puts the
 *   code in the base so `match: {err: {code}}` asserts on the field
 *   rather than on message prose.
 *
 * Run with `make omni-check`. Skips cleanly when omni is not checked
 * out beside this repo: it is a cross-repo check, not a gate.
 */

'use strict'

const Path = require('path')
const Fs = require('fs')

const OMNI = process.env.OMNI || Path.join(__dirname, '..', '..', 'omni')
const RUNNER = Path.join(OMNI, 'javascript', 'src', 'runner.js')
const SPEC = Path.join(__dirname, '..', 'spec', 'plugin.json')

if (!Fs.existsSync(RUNNER)) {
  console.log('plugin: omni not found at ' + OMNI + ' - skipping (set OMNI=<path>)')
  process.exit(0)
}

const { makeRunner } = require(RUNNER)
const P = require(Path.join(__dirname, '..', 'javascript', 'src', 'index.js'))
const { drive } = require(Path.join(__dirname, '..', 'javascript', 'test', 'driver.js'))

// plugin's errors carry a code; omni's default base does not. See above.
const provider = {
  errify: (err) => ({
    name: 'Error',
    message: String(err && err.message),
    code: err && err.code,
  }),
}

// The pure sections, by group. omni calls a subject with the entry's
// ARGUMENTS, where plugin's own runners hand it the whole entry - so
// these read `v` where plugin's read `e.in`.
const PURE = {
  ref: {
    parse: (v) => P.parseref(v),
    parsebad: (v) => P.parseref(v),
    format: (a, b) => P.formatref(a, b),
    formatbad: (a, b) => P.formatref(a, b),
    canon: (v) => P.canonref(v),
    name: (v) => P.checkname(v),
    tag: (v) => P.checktag(v),
    bound: (v) => P.checkname(v),
    boundtag: (v) => P.checktag(v),
  },
  env: {
    option: (v) => P.applyenv(v),
    value: (v) => P.applyenv(v),
    toggle: (v) => P.applyenv(v),
    profile: (v) => P.applyenv(v),
    ambiguous: (v) => P.applyenv(v),
    reserved: (v) => P.applyenv(v),
  },
  version: {
    range: (v) => P.parserange(v),
    rangebad: (v) => P.parserange(v),
    satisfies: (v) => P.satisfies(v.version, v.range),
  },
  capability: {
    match: (v) => P.resolvecapability(v.req, v.candidates),
    nested: (v) => P.resolvecapability(v.req, v.candidates),
    rank: (v) => P.resolvecapability(v.req, v.candidates),
  },
  graph: {
    resolve: (v) => P.resolvegraph(v),
    blocked: (v) => P.resolvegraph(v),
  },
  resolve: {
    candidates: (v) => P.resolvecandidates(v.name, v.sources),
    from: (v) => P.resolvefrom(v),
  },
}

// `config` dispatches by group PREFIX, as plugin's own runners do.
function configsubject(group) {
  if (group.startsWith('norm')) return (v) => P.normalizeconfig(v)
  if (group.startsWith('opt')) return (v) => P.resolveoptions(v)
  return null
}

// Every entry is a command list against a fresh host.
const DRIVER = [
  'lifecycle', 'order', 'point', 'export', 'depend', 'declare',
  'state', 'resource', 'nest', 'trace', 'apply', 'error',
]

async function main() {
  const runner = await makeRunner(SPEC, provider)
  const spec = JSON.parse(Fs.readFileSync(SPEC, 'utf8'))
  const sections = Object.keys(spec.primary).sort()

  let entries = 0
  let ran = 0
  const missing = []

  for (const section of sections) {
    const R = await runner(section)

    for (const group of Object.keys(R.spec)) {
      const set = R.spec[group]
      if (null == set || null == set.set) continue

      const subject =
        DRIVER.includes(section) ? (cmds) => drive(cmds)
          : 'config' === section ? configsubject(group)
            : (PURE[section] || {})[group]

      if (null == subject) {
        missing.push(section + '/' + group)
        continue
      }

      const flags = { name: section + '/' + group, null: false }
      await R.runsetflags(set, flags, subject)
      entries += set.set.length
      ran += 1
    }
  }

  if (0 < missing.length) {
    console.error('plugin: corpus groups with no subject: ' + missing.join(', '))
    process.exit(1)
  }

  // A floor, not a fixture: a run that suddenly covers a fraction of the
  // corpus is the failure worth catching.
  if (400 > entries) {
    console.error('plugin: only ' + entries + ' entries ran under omni')
    process.exit(1)
  }

  console.log(
    'plugin: omni ran ' + entries + ' corpus entries across ' +
    sections.length + ' sections (' + ran + ' groups), all pass'
  )
}

main().catch((err) => {
  console.error('plugin: omni run failed: ' + (err && err.message))
  process.exit(1)
})
