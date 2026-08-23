/* The P2 pure sections: env, version, capability, graph, resolve. */

import { test } from 'node:test'
import * as Assert from 'node:assert'

import { section, check, label, Entry } from './corpus'
import {
  applyenv, parserange, satisfies,
  resolvecapability, resolvegraph, resolvecandidates, resolvefrom,
} from '../src/index'

const SUBJECT: { [sec: string]: { [group: string]: (e: Entry) => any } } = {
  env: {
    option: (e) => applyenv(e.in),
    value: (e) => applyenv(e.in),
    toggle: (e) => applyenv(e.in),
    profile: (e) => applyenv(e.in),
    ambiguous: (e) => applyenv(e.in),
    reserved: (e) => applyenv(e.in),
  },
  version: {
    range: (e) => parserange(e.in),
    rangebad: (e) => parserange(e.in),
    satisfies: (e) => satisfies(e.in.version, e.in.range),
  },
  capability: {
    match: (e) => resolvecapability(e.in.req, e.in.candidates),
    nested: (e) => resolvecapability(e.in.req, e.in.candidates),
    rank: (e) => resolvecapability(e.in.req, e.in.candidates),
  },
  graph: {
    resolve: (e) => resolvegraph(e.in),
    blocked: (e) => resolvegraph(e.in),
  },
  resolve: {
    candidates: (e) => resolvecandidates(e.in.name, e.in.sources),
    from: (e) => resolvefrom(e.in),
  },
}

for (const sec of Object.keys(SUBJECT)) {
  const groups = section(sec)

  test(sec + ': every group is dispatched', () => {
    const unknown = Object.keys(groups).filter((g) => !SUBJECT[sec][g])
    Assert.deepEqual(unknown, [], 'corpus groups with no subject: ' + unknown.join(', '))
  })

  for (const g of Object.keys(groups)) {
    test(sec + '/' + g, () => {
      const subject = SUBJECT[sec][g]
      if (!subject) return
      const fails: string[] = []
      groups[g].forEach((e, i) => {
        const why = check(e, subject)
        if (why) fails.push(label(g, i, e) + ': ' + why)
      })
      Assert.deepEqual(fails, [], fails.join('\n'))
    })
  }
}
