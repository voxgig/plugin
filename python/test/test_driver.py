"""The DRIVER sections: everything a command list drives."""

import unittest

from test.corpus import check, label, section
from test.driver import drive

DRIVER_SECTIONS = [
    'lifecycle', 'order', 'point', 'export', 'depend',
    'declare', 'state', 'resource', 'nest', 'trace', 'apply', 'error',
]


class DriverTest(unittest.TestCase):

    def test_every_entry_carries_cmd(self):
        bad = []
        for name in DRIVER_SECTIONS:
            groups = section(name)
            for group in sorted(groups):
                for i, entry in enumerate(groups[group]):
                    if not isinstance(entry.get('in'), list):
                        bad.append(name + '/' + label(group, i, entry))
        self.assertEqual([], bad, 'driver entries without a command list in `in`: ' + str(bad))

    def test_driver_sections(self):
        fails = []
        for name in DRIVER_SECTIONS:
            groups = section(name)
            for group in sorted(groups):
                for i, entry in enumerate(groups[group]):
                    why = check(entry, lambda e: drive(e['in']))
                    if why:
                        fails.append(name + '/' + label(group, i, entry) +
                                     ': ' + why)
        self.assertEqual([], fails, '\n'.join(fails))


if '__main__' == __name__:
    unittest.main()
