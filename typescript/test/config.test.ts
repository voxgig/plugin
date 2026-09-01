/* `config` — normalization and the ten-level ladder. */

import { test } from 'node:test'
import * as Assert from 'node:assert'

import { section, check, label, Entry } from './corpus'
import { normalizeconfig, resolveoptions } from '../dist/index'

const groups = section('config')

function subjectfor(group: string): ((e: Entry) => any) | null {
  if (group.startsWith('norm')) return (e) => normalizeconfig(e.in)
  if (group.startsWith('opt')) return (e) => resolveoptions(e.in)
  return null
}

test('config: every group is dispatched', () => {
  const unknown = Object.keys(groups).filter((g) => !subjectfor(g))
  Assert.deepEqual(unknown, [], 'corpus groups with no subject: ' + unknown.join(', '))
})

for (const g of Object.keys(groups)) {
  test('config/' + g, () => {
    const subject = subjectfor(g)
    if (!subject) return
    const fails: string[] = []
    groups[g].forEach((e, i) => {
      const why = check(e, subject)
      if (why) fails.push(label(g, i, e) + ': ' + why)
    })
    Assert.deepEqual(fails, [], fails.join('\n'))
  })
}
