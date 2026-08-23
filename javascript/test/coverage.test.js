/* EVERY CORPUS SECTION IS RUN.
 *
 * The per-section tests already fail on a GROUP with no subject. This
 * closes the level above: a whole SECTION the runner never mentions is a
 * section silently not run, and it would pass a suite that claims the
 * port passes every corpus section.
 *
 * It also counts the entries, so a section that decodes to an empty set
 * cannot masquerade as a passing one. */

'use strict'

const { test } = require('node:test')
const Assert = require('node:assert')

const { corpus, section } = require('./corpus')
const { DRIVER_SECTIONS } = require('./driver.test')

/** The sections driven by a direct function call; the names must match
 * the map keys the pure tests dispatch. */
const PURE_SECTIONS = ['ref', 'env', 'version', 'capability', 'graph',
  'resolve', 'config']

test('every corpus section is run', () => {
  const spec = corpus()
  const primary = spec.primary || {}

  // The corpus metadata block is what turns on strict entry validation
  // in every runner, so a corpus that lost it must not silently
  // downgrade this port's checking.
  Assert.equal(1, (spec.PLUGIN || {}).version, 'corpus PLUGIN.version must be 1')

  const run = new Set(PURE_SECTIONS.concat(DRIVER_SECTIONS))

  const missing = Object.keys(primary).filter((n) => !run.has(n)).sort()
  Assert.deepEqual(missing, [], 'corpus sections no test runs: ' + missing.join(', '))

  const extra = Array.from(run).filter((n) => !primary[n]).sort()
  Assert.deepEqual(extra, [],
    'tests name sections the corpus does not have: ' + extra.join(', '))

  let total = 0
  for (const name of Array.from(run).sort()) {
    const groups = section(name)
    const count = Object.keys(groups).reduce((n, g) => n + groups[g].length, 0)
    Assert.ok(0 < count, 'section ' + name + ' has no entries')
    total += count
  }

  // A floor, not a fixture: the corpus grows, and a run that suddenly
  // covers a fraction of it is the failure worth catching.
  Assert.ok(400 <= total, 'only ' + total + ' corpus entries reachable')
})
