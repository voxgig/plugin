/* `ref` — the first section a port passes. */

'use strict'

const { test } = require('node:test')
const Assert = require('node:assert')

const { section, check, label } = require('./corpus')
const { parseref, formatref, checkname, checktag, canonref } = require('../src/index')

// Group name -> subject. Explicit rather than inferred: a runner that
// guessed from the entry's shape would run the wrong function on a
// mistyped entry.
const SUBJECT = {
  parse: (e) => parseref(e.in),
  parsebad: (e) => parseref(e.in),
  format: (e) => formatref(e.args[0], e.args[1]),
  formatbad: (e) => formatref(e.args[0], e.args[1]),
  canon: (e) => canonref(e.in),
  name: (e) => checkname(e.in),
  tag: (e) => checktag(e.in),
  bound: (e) => checkname(e.in),
  boundtag: (e) => checktag(e.in),
}

const groups = section('ref')

// EVERY group must have a subject. A group the runner does not know is a
// group silently not run, which is worse than a failure.
test('ref: every group is dispatched', () => {
  const unknown = Object.keys(groups).filter((g) => !SUBJECT[g])
  Assert.deepEqual(unknown, [], 'corpus groups with no subject: ' + unknown.join(', '))
})

for (const g of Object.keys(groups)) {
  test('ref/' + g, () => {
    const subject = SUBJECT[g]
    if (!subject) return
    const fails = []
    groups[g].forEach((e, i) => {
      const why = check(e, subject)
      if (why) fails.push(label(g, i, e) + ': ' + why)
    })
    Assert.deepEqual(fails, [], fails.join('\n'))
  })
}
