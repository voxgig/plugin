/* The DRIVER sections: everything a command list drives. */

'use strict'

const { test } = require('node:test')
const Assert = require('node:assert')

const { section, check, label } = require('./corpus')
const { drive } = require('./driver')

const DRIVER_SECTIONS = [
  'lifecycle', 'order', 'point', 'export', 'depend',
  'declare', 'state', 'resource', 'nest', 'trace', 'apply', 'error',
]

for (const name of DRIVER_SECTIONS) {
  const groups = section(name)

  test(name + ': every entry carries a command list in `in`', () => {
    const bad = []
    for (const g of Object.keys(groups)) {
      groups[g].forEach((e, i) => {
        if (!Array.isArray(e.in)) bad.push(label(g, i, e))
      })
    }
    Assert.deepEqual(bad, [], 'driver entries without a command list in `in`: ' + bad.join(', '))
  })

  for (const g of Object.keys(groups)) {
    test(name + '/' + g, () => {
      const fails = []
      groups[g].forEach((e, i) => {
        const why = check(e, (en) => drive(en.in))
        if (why) fails.push(label(g, i, e) + ': ' + why)
      })
      Assert.deepEqual(fails, [], fails.join('\n'))
    })
  }
}

module.exports = { DRIVER_SECTIONS }
