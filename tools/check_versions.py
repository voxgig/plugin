#!/usr/bin/env python3
"""Check the repository's release metadata: versions, and the tag list.

ONE VERSION LINE, TWENTY-THREE PORTS. `VERSION` at the repository root is
the single source of truth: `0.1.6` means all twenty-three ports are at
that corpus, and the release tags `<port>/v0.1.6` say so in git. Most
ports declare no version anywhere - they are plain source trees built by
a Makefile - so for those the TAG IS THE VERSION and there is nothing
here to check. The four that do declare one must not drift from the line,
because a published package whose manifest disagrees with its tag is a
package nobody can trace back to a commit.

COMMITTED LOCKFILES COUNT. `npm ci` fails outright when
package-lock.json disagrees with package.json, so a bumped manifest with
a stale lockfile is a release that dies in CI rather than one that ships
wrong. Both npm locks are committed - publish.yml runs `npm ci` - so they
are checked here, and the failure lands at `make check` on a developer's
machine where the fix is one command. rust's Cargo.lock is deliberately
absent: a library crate does not commit one.

AND THE TAG LIST, because a port that no workflow tags is a port that
never ships. `tag.yml` holds its own literal list of ports rather than
parsing the Makefile - it writes irreversible tags and a regex over a
Makefile is not the thing to trust with that - so the two are checked
against each other here instead. Adding a port is a FIVE-place change
(AGENTS.md): the Makefile, check_parity.py, check_probes.py, the CI
matrix, and tag.yml.

WHAT THIS IS NOT: a check that the ports agree with each other about
behaviour. That is the corpus (`spec/plugin.json`) and `check_parity.py`.
This file only asks whether the numbers and the lists match.

Usage: python3 tools/check_versions.py
"""

import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def npm_manifest(text):
    return json.loads(text).get('version')


def npm_lock(text):
    """A v2/v3 lockfile states the version twice and both must move."""
    lock = json.loads(text)
    root = lock.get('packages', {}).get('', {})
    top, inner = lock.get('version'), root.get('version')
    return top if top == inner else '%s/%s (lockfile disagrees with itself)' % (top, inner)


def toml_field(section):
    """`version = "x"` in the named table, not in some later one."""
    def read(text):
        body = re.split(r'^\[', text, flags=re.M)
        for part in body:
            if part.startswith(section + ']'):
                found = re.search(r'^\s*version\s*=\s*"([^"]+)"', part, re.M)
                return found.group(1) if found else None
        return None
    return read


# Every file that states a version. A port absent from this list states
# none, and its release is the git tag alone.
MANIFESTS = [
    ('typescript', 'typescript/package.json', npm_manifest),
    ('typescript', 'typescript/package-lock.json', npm_lock),
    ('javascript', 'javascript/package.json', npm_manifest),
    ('javascript', 'javascript/package-lock.json', npm_lock),
    ('python', 'python/pyproject.toml', toml_field('project')),
    ('rust', 'rust/Cargo.toml', toml_field('package')),
    # NOT rust/Cargo.lock: a library crate does not commit one (.gitignore),
    # cargo regenerates it from Cargo.toml, and requiring it here would fail
    # on any fresh checkout - which is every CI run.
]


def portlist(text, pattern):
    found = re.search(pattern, text, re.M | re.S)
    return sorted(found.group(1).split()) if found else None


def check_tag_list():
    """tag.yml must offer every port the Makefile builds, and no other."""
    with open(os.path.join(ROOT, 'Makefile')) as handle:
        langs = portlist(handle.read(), r'^LANGS\s*=\s*(.*?)(?=\n\S|\n\n)')
    with open(os.path.join(ROOT, '.github/workflows/tag.yml')) as handle:
        tagged = portlist(handle.read(), r"^\s*ALL='([^']*)'")

    if langs is None or tagged is None:
        print('plugin: could not read the port list from %s'
              % ('Makefile' if langs is None else 'tag.yml'), file=sys.stderr)
        return 1
    if langs != tagged:
        missing = [p for p in langs if p not in tagged]
        extra = [p for p in tagged if p not in langs]
        if missing:
            print('tag.yml does not tag: %s' % ' '.join(missing), file=sys.stderr)
        if extra:
            print('tag.yml names non-ports: %s' % ' '.join(extra), file=sys.stderr)
        return 1

    print('\ntag.yml tags all %d ports the Makefile builds' % len(langs))
    return 0


def main():
    version_file = os.path.join(ROOT, 'VERSION')
    if not os.path.exists(version_file):
        print('plugin: VERSION is missing from the repository root', file=sys.stderr)
        return 1

    with open(version_file) as handle:
        version = handle.read().strip()

    # Plain semver, because the go port's tag is derived from this and the
    # go command rejects anything else - permanently, see tag.yml.
    if not re.match(r'^[0-9]+\.[0-9]+\.[0-9]+$', version):
        print('plugin: VERSION %r is not X.Y.Z' % version, file=sys.stderr)
        return 1

    bad = 0
    for port, relative, read in MANIFESTS:
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            print('%-12s %-32s MISSING' % (port, relative))
            bad += 1
            continue
        with open(path) as handle:
            found = read(handle.read())
        if found == version:
            print('%-12s %-32s %s' % (port, relative, found))
        else:
            print('%-12s %-32s %s  != VERSION %s' % (port, relative, found, version))
            bad += 1

    if bad:
        print('\nplugin: %d manifest(s) disagree with VERSION %s' % (bad, version),
              file=sys.stderr)
        return 1

    if check_tag_list():
        return 1

    print('\nplugin: every declared version is %s' % version)
    return 0


if __name__ == '__main__':
    sys.exit(main())
