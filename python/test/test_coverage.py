"""EVERY CORPUS SECTION IS RUN.

The per-section tests already fail on a GROUP with no subject. This closes
the level above: a whole SECTION the runner never mentions is a section
silently not run, and it would pass a suite that claims P4's exit ("both
pass every corpus section").

It also counts the entries, so a section that decodes to an empty set
cannot masquerade as a passing one.
"""

import unittest

from test.corpus import corpus, section
from test.test_driver import DRIVER_SECTIONS

# The sections driven by a direct function call; the names must match the
# map keys the pure tests dispatch.
PURE_SECTIONS = ['ref', 'env', 'version', 'capability', 'graph', 'resolve',
                 'config']


class CoverageTest(unittest.TestCase):

    def test_every_section_is_run(self):
        spec = corpus()
        primary = spec.get('primary') or {}

        # The corpus metadata block is what turns on strict entry
        # validation in every runner, so a corpus that lost it must not
        # silently downgrade this port's checking.
        self.assertEqual(1, (spec.get('PLUGIN') or {}).get('version'),
                         'corpus PLUGIN.version must be 1')

        run = set(PURE_SECTIONS) | set(DRIVER_SECTIONS)

        missing = sorted(name for name in primary if name not in run)
        self.assertEqual([], missing,
                         'corpus sections no test runs: ' + str(missing))

        extra = sorted(name for name in run if name not in primary)
        self.assertEqual([], extra,
                         'tests name sections the corpus does not have: ' +
                         str(extra))

        total = 0
        for name in sorted(run):
            groups = section(name)
            count = sum(len(groups[g]) for g in groups)
            self.assertLess(0, count, 'section ' + name + ' has no entries')
            total += count

        # A floor, not a fixture: the corpus grows, and a run that
        # suddenly covers a fraction of it is the failure worth catching.
        self.assertLessEqual(400, total,
                             'only %d corpus entries reachable' % total)


if '__main__' == __name__:
    unittest.main()
