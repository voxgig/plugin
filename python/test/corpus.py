"""The corpus runner.

Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
exactly as every other port's runner does. No port needs a Node toolchain
to run its tests, and this one does not get a private door into the source
either.

A group name selects the subject. That is the whole dispatch, and it is
deliberately dumb: a runner that inferred the subject from the entry's
shape would silently run the wrong function when an entry was mistyped.
"""

import json
import os
import re

from voxgig_plugin import codeof

SPEC = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                    '..', '..', 'spec', 'plugin.json')

# The markers the corpus uses inside `match`.
EXISTS, UNDEF, NULL = '__EXISTS__', '__UNDEF__', '__NULL__'

# A sentinel for "this key was not present", which Python's `dict.get`
# collapses into None just as JavaScript collapses absent into undefined -
# except JavaScript has `undefined` AND `null` and Python has only `None`.
MISSING = object()


def corpus():
    with open(SPEC, encoding='utf-8') as handle:
        return json.load(handle)


def section(name):
    spec = corpus()
    sec = (spec.get('primary') or {}).get(name)
    if None is sec:
        raise Exception('no such corpus section: ' + name)
    out = {}
    for group in sec:
        if 'DEF' == group:
            continue
        entries = sec[group].get('set') if isinstance(sec[group], dict) else None
        if isinstance(entries, list):
            out[group] = entries
    return out


def label(group, i, entry):
    """A stable label, so a failure names the entry rather than an
    index."""
    return entry.get('id') or (group + '#' + str(i))


def same(a, b):
    """Deep equality over spec values. Key order never matters; list order
    always does.

    PYTHON'S `True == 1` IS THE HAZARD HERE, and it is not theoretical: an
    entry asserting `out: false` would be satisfied by a port returning
    `0`, silently, in exactly the predicates (`check_name`, `satisfies`)
    where that is the whole answer.
    """
    if isinstance(a, bool) != isinstance(b, bool):
        return False
    if isinstance(a, dict) and isinstance(b, dict):
        if len(a) != len(b):
            return False
        for key in a:
            if key not in b or not same(a[key], b[key]):
                return False
        return True
    if isinstance(a, list) or isinstance(b, list):
        if not isinstance(a, list) or not isinstance(b, list):
            return False
        if len(a) != len(b):
            return False
        return all(same(a[i], b[i]) for i in range(len(a)))
    return a == b


def matches(expect, actual):
    """Partial match: every key the expectation names must agree, and keys
    it does not name are ignored. `__EXISTS__` asserts presence without
    pinning a value; `/re/` matches a string as a regular expression."""
    if EXISTS == expect:
        return MISSING is not actual and None is not actual
    if UNDEF == expect:
        return MISSING is actual
    if NULL == expect:
        return MISSING is not actual and None is actual

    if MISSING is actual:
        actual = None

    if isinstance(expect, str) and 2 < len(expect) \
            and expect.startswith('/') and expect.endswith('/'):
        if not isinstance(actual, str):
            return False
        return None is not re.search(expect[1:-1], actual)

    if isinstance(expect, list):
        if not isinstance(actual, list) or len(expect) != len(actual):
            return False
        return all(matches(expect[i], actual[i]) for i in range(len(expect)))

    if isinstance(expect, dict):
        if not isinstance(actual, dict):
            return False
        for key in expect:
            if not matches(expect[key],
                           actual[key] if key in actual else MISSING):
                return False
        return True

    if isinstance(expect, bool) != isinstance(actual, bool):
        return False
    return expect == actual


def check(entry, subject):
    """Run one entry against a subject and report the disagreement, if
    any.

    The three combinations the spec format allows are enforced here as
    well as at build time, because a runner that quietly accepted `err`
    beside `out` would let a contradictory entry pass.
    """
    if 'err' in entry and 'out' in entry:
        return 'entry has both err and out'

    value = None
    raised = None
    try:
        value = subject(entry)
    except Exception as err:
        raised = err

    if 'err' in entry:
        if None is raised:
            return 'expected a raise, got: ' + json.dumps(value, default=str)
        if True is not entry['err']:
            # Errors compare by CODE (section 12). Message wording is a
            # port's own business, and pinning it would make every
            # translation a corpus change.
            got = codeof(raised)
            if got != entry['err']:
                return ('expected code ' + entry['err'] + ', got ' +
                        str(got) + ' (' + str(raised) + ')')
        if 'match' in entry:
            got = {'err': {'code': codeof(raised), 'message': str(raised),
                           'name': 'PluginError'}}
            if not matches(entry['match'], got):
                return ('error did not match ' + json.dumps(entry['match']) +
                        ', got ' + json.dumps(got))
        return None

    if None is not raised:
        return 'unexpected raise: ' + str(codeof(raised)) + ' ' + str(raised)

    if 'out' in entry:
        if not same(entry['out'], value):
            return ('expected ' + json.dumps(entry['out']) + ', got ' +
                    json.dumps(value, default=str))

    if 'match' in entry:
        got = {'in': entry.get('in'), 'out': value}
        if not matches(entry['match'], got):
            return ('did not match ' + json.dumps(entry['match']) +
                    ', got out=' + json.dumps(value, default=str))

    if 'out' not in entry and 'match' not in entry:
        return 'entry asserts nothing'

    return None
