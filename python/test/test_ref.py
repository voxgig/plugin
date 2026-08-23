"""`ref` - the first section a port passes."""

import unittest

from voxgig_plugin import (canon_ref, check_name, check_tag, format_ref,
                           parse_ref)
from test.corpus import check, label, section


def arg(entry, i):
    args = entry.get('args') or []
    return args[i] if i < len(args) else None


# SUBJECT maps a group name to the function under test. Explicit rather
# than inferred: a runner that guessed from the entry's shape would run
# the wrong function on a mistyped entry.
SUBJECT = {
    'parse': lambda e: parse_ref(e.get('in')),
    'parsebad': lambda e: parse_ref(e.get('in')),
    'format': lambda e: format_ref(arg(e, 0), arg(e, 1)),
    'formatbad': lambda e: format_ref(arg(e, 0), arg(e, 1)),
    'canon': lambda e: canon_ref(e.get('in')),
    'name': lambda e: check_name(e.get('in')),
    'tag': lambda e: check_tag(e.get('in')),
    'bound': lambda e: check_name(e.get('in')),
    'boundtag': lambda e: check_tag(e.get('in')),
}


class RefTest(unittest.TestCase):
    def test_ref(self):
        runsection(self, 'ref', SUBJECT)


def runsection(case, name, subject):
    """The whole of every pure section's test: dispatch every group, and
    fail on a group the runner does not know - a group silently not run is
    worse than a failure."""
    groups = section(name)
    fails = []
    for group in sorted(groups):
        fn = subject.get(group)
        if None is fn:
            fails.append(name + ': corpus group with no subject: ' + group)
            continue
        for i, entry in enumerate(groups[group]):
            why = check(entry, fn)
            if why:
                fails.append(label(group, i, entry) + ': ' + why)
    case.assertEqual([], fails, '\n'.join(fails))


if '__main__' == __name__:
    unittest.main()
