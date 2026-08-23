#!/usr/bin/env python3
"""Every port implements every probe definition.

The probe catalog is a CONTRACT, not a test fixture: DOCS.md §4.3 says
their behaviour "is as much the contract as the runner is", because a
driver section's expected `log` is written against what `noisy` does. A
port whose `noisy` fails at a different callback passes its own suite
and disagrees with every other port.

This checks PRESENCE, not behaviour — behaviour is what the corpus is
for. A port that names all six and implements one of them wrongly fails
`lifecycle`, loudly, which is where that belongs.

Same shape as check_parity.py deliberately: two checkers that scan
source the same way are one thing to learn.
"""

import os
import re
import sys

# DOCS.md §4.3. Adding one here means adding it there in the same change
# — a probe with no documented behaviour is a name twenty ports will
# each guess at.
PROBES = [
    'probe',     # the workhorse: records callbacks, one resource per activation
    'noisy',     # fails on demand at a named callback
    'greedy',    # acquires N, releases some — the difference is the scope's job
    'dep',       # declares requirements
    'provider',  # binds a provider point
    'slow',      # yields where the language has async, to prove eager settling
]

# Where each port's DRIVER lives. Test code, unlike check_parity.py,
# because the probes are the driver's and not the library's.
PORTS = {
    'typescript': ['typescript/test'],
}

SKIP_DIRS = {'node_modules', 'dist', 'build', 'target', '__pycache__', 'bin', 'obj'}


def sources(paths):
    out = []
    for path in paths:
        if not os.path.isdir(path):
            continue
        for root, dirs, files in os.walk(path):
            dirs[:] = [d for d in dirs if d not in SKIP_DIRS]
            for f in files:
                out.append(os.path.join(root, f))
    return out


def found(paths):
    """A probe counts as present if its name appears as a quoted string.

    Deliberately loose. A tighter pattern would have to know nine
    languages' syntax for a string literal, and the thing worth catching
    is an ABSENT probe rather than an oddly-spelled one.
    """
    hits = set()
    for path in sources(paths):
        try:
            with open(path, 'r', encoding='utf-8', errors='ignore') as fh:
                text = fh.read()
        except OSError:
            continue
        for probe in PROBES:
            if re.search(r'''["'`]%s["'`]''' % re.escape(probe), text):
                hits.add(probe)
    return hits


def main():
    print('plugin probes: %d definitions\n' % len(PROBES))

    if not PORTS:
        for p in PROBES:
            print('  %s' % p)
        print('\nplugin: no ports yet')
        return 0

    problems = 0
    for port in sorted(PORTS):
        hits = found(PORTS[port])
        missing = [p for p in PROBES if p not in hits]
        if missing:
            print('%-12s MISSING: %s' % (port, ', '.join(missing)))
            problems += 1
        else:
            print('%-12s ok' % port)

    if problems:
        print('\nplugin: %d port(s) missing probe definitions' % problems)
        print('The catalog is in DOCS.md §4.3 — a driver section is')
        print('unrunnable without every one of them.')
        return 1

    print('\nplugin: all ports implement every probe')
    return 0


if __name__ == '__main__':
    sys.exit(main())
