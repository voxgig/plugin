/* `ref` — the first section a port passes. */

import { test } from 'node:test'
import * as Assert from 'node:assert'

import { section, check, label, Entry } from './corpus'
import { parseref, formatref, checkname, checktag, canonref } from '../src/index'

// Group name -> subject. Explicit rather than inferred: a runner that
// guessed from the entry's shape would run the wrong function on a
// mistyped entry.
const SUBJECT: { [group: string]: (e: Entry) => any } = {
  parse: (e) => parseref(e.in),
  parsebad: (e) => parseref(e.in),
  format: (e) => formatref((e.args as any[])[0], (e.args as any[])[1]),
  formatbad: (e) => formatref((e.args as any[])[0], (e.args as any[])[1]),
  canon: (e) => canonref(e.in),
  name: (e) => checkname(e.in),
  tag: (e) => checktag(e.in),
  bound: (e) => checkname(e.in),
  boundtag: (e) => checktag(e.in),
}

const groups = section('ref')

// EVERY group must have a subject. A group the runner does not know is
// a group silently not run, which is worse than a failure.
test('ref: every group is dispatched', () => {
  const unknown = Object.keys(groups).filter((g) => !SUBJECT[g])
  Assert.deepEqual(unknown, [], 'corpus groups with no subject: ' + unknown.join(', '))
})

for (const g of Object.keys(groups)) {
  test('ref/' + g, () => {
    const subject = SUBJECT[g]
    if (!subject) return
    const fails: string[] = []
    groups[g].forEach((e, i) => {
      const why = check(e, subject)
      if (why) fails.push(label(g, i, e) + ': ' + why)
    })
    Assert.deepEqual(fails, [], fails.join('\n'))
  })
}
