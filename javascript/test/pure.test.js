/* The pure sections: env, version, capability, graph, resolve, config. */

'use strict'

const { test } = require('node:test')
const Assert = require('node:assert')

const { section, check, label } = require('./corpus')
const {
  applyenv, parserange, satisfies, normalizeconfig, resolveoptions,
  resolvecapability, resolvegraph, resolvecandidates, resolvefrom,
} = require('../src/index')

const SUBJECT = {
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
      const fails = []
      groups[g].forEach((e, i) => {
        const why = check(e, subject)
        if (why) fails.push(label(g, i, e) + ': ' + why)
      })
      Assert.deepEqual(fails, [], fails.join('\n'))
    })
  }
}

// `config` picks its subject by group PREFIX rather than by name, because
// the two functions split the section cleanly and a per-group map would
// be thirteen rows saying the same two things.
const configgroups = section('config')

function subjectfor(group) {
  if (group.startsWith('norm')) return (e) => normalizeconfig(e.in)
  if (group.startsWith('opt')) return (e) => resolveoptions(e.in)
  return null
}

test('config: every group is dispatched', () => {
  const unknown = Object.keys(configgroups).filter((g) => !subjectfor(g))
  Assert.deepEqual(unknown, [], 'corpus groups with no subject: ' + unknown.join(', '))
})

for (const g of Object.keys(configgroups)) {
  test('config/' + g, () => {
    const subject = subjectfor(g)
    if (!subject) return
    const fails = []
    configgroups[g].forEach((e, i) => {
      const why = check(e, subject)
      if (why) fails.push(label(g, i, e) + ': ' + why)
    })
    Assert.deepEqual(fails, [], fails.join('\n'))
  })
}
