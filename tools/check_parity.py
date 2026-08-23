#!/usr/bin/env python3
"""Check that every plugin port defines the canonical API.

The canonical API is the export list of the TypeScript port
(typescript/src/index.ts). Every other port must define every name, in
local casing - matching is case- and underscore-insensitive, exactly as in
voxgig/struct and voxgig/omni.

SCOPE: this is a NAME check, not a behaviour check. It confirms each
canonical identifier appears as a token in a port's source (it scans raw
text, so a name in a comment counts). It does NOT verify that a port's
`normalizeconfig`, `resolveorder`, etc. behave like the canonical - a port
whose `resolveorder` returned its input unchanged would pass here.
Behavioural parity is the job of `spec/plugin.json` (run per port) plus
`check_probes.py` over the driver catalog.

P0 STATE: PORTS is empty. Nothing is ported yet, so this reports the
canonical surface and exits 0 - it is wired into `make parity` now so that
the first port added is checked from its first commit, rather than parity
arriving after there is already drift to find. An empty run is a real
result, not a skipped one, and it says so.

Usage: python3 tools/check_parity.py
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# The canonical public surface (design §16). Deliberately small: everything
# else is methods on the host and instance types, which parity cannot check
# by name and the corpus checks by behaviour.
CANONICAL = [
    # host construction
    'makehost',
    'makecatalog',
    # refs - the first thing a new port implements (§4)
    'parseref',
    'formatref',
    'checkname',
    'checktag',
    # pure functions over documents and definitions
    'normalizeconfig',
    'resolveoptions',
    'resolveorder',
    'resolvecandidates',
    'applyenv',
]

# Where each port's library source lives (test code is not scanned).
# P4 adds python next; P5 and P6 the rest.
PORTS = {
    'typescript': ['typescript/src'],
    'go': ['go/plugin'],
}

SKIP_DIRS = {'node_modules', 'dist', 'build', 'target', '__pycache__', 'bin', 'obj', '.lake'}

# Documented per-port variance. A port may only appear here for a name it
# genuinely cannot express; the reason is printed on every run.
EXEMPT = {}


def normal(name):
    """Case- and underscore-insensitive form of a name."""
    return re.sub(r'[_\-]', '', name).lower()


def variants(name):
    """A name, plus the form without a namespace prefix (C uses plugin_*)."""
    key = normal(name)
    out = {key}
    if key.startswith('plugin') and 6 < len(key):
        out.add(key[6:])
    return out


def sources(paths):
    """Every source file under the given paths."""
    out = []

    for path in paths:
        full = os.path.join(ROOT, path)

        if os.path.isfile(full):
            out.append(full)
            continue

        for dirpath, dirnames, filenames in os.walk(full):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for filename in filenames:
                if filename.startswith('.'):
                    continue
                out.append(os.path.join(dirpath, filename))

    return out


def defined(paths):
    """The set of identifiers a port's source defines, normalised."""
    found = set()

    for path in sources(paths):
        try:
            with open(path, encoding='utf-8') as handle:
                text = handle.read()
        except (OSError, UnicodeDecodeError):
            continue

        for token in re.findall(r'[A-Za-z_][A-Za-z0-9_\-]*', text):
            found |= variants(token)

    return found


def main():
    want = [(name, normal(name)) for name in CANONICAL]
    problems = 0

    print('plugin parity: %d canonical names\n' % len(CANONICAL))

    if not PORTS:
        for name in CANONICAL:
            print('  %s' % name)
        print('\nplugin: no ports yet - add one to PORTS as it lands (P1: typescript)')
        return 0

    for port in sorted(PORTS):
        found = defined(PORTS[port])
        exempt = EXEMPT.get(port, {})
        missing = [name for name, key in want if key not in found and name not in exempt]

        for name, reason in sorted(exempt.items()):
            print('%-12s exempt: %s (%s)' % (port, name, reason))

        if missing:
            problems += 1
            print('%-12s MISSING: %s' % (port, ', '.join(missing)))
        else:
            print('%-12s ok' % port)

    print('')

    if problems:
        print('plugin: %d port(s) incomplete' % problems)
        return 1

    print('plugin: all ports complete')
    return 0


if __name__ == '__main__':
    sys.exit(main())
