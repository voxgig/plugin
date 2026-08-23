"""The P2 pure sections: env, version, capability, graph, resolve - plus
config, whose two functions the group name selects."""

import unittest

from voxgig_plugin import (apply_env, normalize_config, parse_range,
                           resolve_candidates, resolve_capability,
                           resolve_from, resolve_graph, resolve_options,
                           satisfies)
from test.corpus import check, label, section
from test.test_ref import runsection


class PureTest(unittest.TestCase):

    def test_env(self):
        run = lambda e: apply_env(e.get('in'))
        runsection(self, 'env', {
            'option': run, 'value': run, 'toggle': run,
            'profile': run, 'ambiguous': run, 'reserved': run,
        })

    def test_version(self):
        rng = lambda e: parse_range(e.get('in'))
        runsection(self, 'version', {
            'range': rng,
            'rangebad': rng,
            'satisfies': lambda e: satisfies(e['in']['version'],
                                             e['in']['range']),
        })

    def test_capability(self):
        run = lambda e: resolve_capability(e['in']['req'],
                                           e['in']['candidates'])
        runsection(self, 'capability',
                   {'match': run, 'nested': run, 'rank': run})

    def test_graph(self):
        run = lambda e: resolve_graph(e.get('in'))
        runsection(self, 'graph', {'resolve': run, 'blocked': run})

    def test_resolve(self):
        runsection(self, 'resolve', {
            'candidates': lambda e: resolve_candidates(
                e['in']['name'], e['in'].get('sources')),
            'from': lambda e: resolve_from(e.get('in')),
        })

    def test_config(self):
        groups = section('config')
        fails = []
        for group in sorted(groups):
            if group.startswith('norm'):
                fn = lambda e: normalize_config(e.get('in'))
            elif group.startswith('opt'):
                fn = lambda e: resolve_options(e.get('in'))
            else:
                fails.append('config: corpus group with no subject: ' + group)
                continue
            for i, entry in enumerate(groups[group]):
                why = check(entry, fn)
                if why:
                    fails.append(label(group, i, entry) + ': ' + why)
        self.assertEqual([], fails, '\n'.join(fails))


if '__main__' == __name__:
    unittest.main()
