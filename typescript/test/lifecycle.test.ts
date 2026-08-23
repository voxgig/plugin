/* `lifecycle` and `order` — the DRIVER sections. */

import { test } from 'node:test'
import * as Assert from 'node:assert'

import { section, check, label, Entry } from './corpus'
import { drive } from './driver'

for (const name of ['lifecycle', 'order']) {
  const groups = section(name)

  test(name + ': every entry carries cmd', () => {
    const bad: string[] = []
    for (const g of Object.keys(groups)) {
      groups[g].forEach((e, i) => {
        if (!Array.isArray(e.cmd)) bad.push(label(g, i, e))
      })
    }
    Assert.deepEqual(bad, [], 'driver entries without cmd: ' + bad.join(', '))
  })

  for (const g of Object.keys(groups)) {
    test(name + '/' + g, () => {
      const fails: string[] = []
      groups[g].forEach((e: Entry, i) => {
        const why = check(e, (en) => drive(en.cmd as any[]))
        if (why) fails.push(label(g, i, e) + ': ' + why)
      })
      Assert.deepEqual(fails, [], fails.join('\n'))
    })
  }
}
