"""Versions and ranges (section 11.2).

TWO FIELDS AND ONE PREDICATE. A capability declares `version`, a concrete
version. A requirement declares `range`. A requirement is satisfied when
the names match, the `match` passes, and:

  the provider's `version` falls inside the requirement's `range`.

That is the whole rule. There is no third field and no second comparison -
an earlier draft added a provider-side `compat` range, which left three
values and no statement of how they combine, and three defensible
readings of one declaration is worse than the ambiguity it was introduced
to fix.
"""

import re

from .types import fail

VERSION_RE = re.compile(r'^(\d+)(?:\.(\d+))?(?:\.(\d+))?$')


def parse_range(text):
    """Two forms and no more (section 11.2):

      '2.1'    >= 2.1.0 and < 3.0.0
      '~2.1'   >= 2.1.0 and < 2.2.0
    """
    if not isinstance(text, str) or 0 == len(text):
        fail('plugin_bad_range', 'invalid range: ' + str(text),
             {'range': text})

    tilde = text.startswith('~')
    body = text[1:] if tilde else text
    found = VERSION_RE.match(body)
    if None is found:
        fail('plugin_bad_range', 'invalid range: ' + text, {'range': text})

    major = int(found.group(1))
    minor = 0 if None is found.group(2) else int(found.group(2))
    patch = 0 if None is found.group(3) else int(found.group(3))

    lo = [major, minor, patch]
    hi = [major, minor + 1, 0] if tilde else [major + 1, 0, 0]
    return {'lo': lo, 'hi': hi}


def parse_version(text):
    if not isinstance(text, str):
        fail('plugin_bad_range', 'invalid version: ' + str(text),
             {'version': text})
    found = VERSION_RE.match(text)
    if None is found:
        fail('plugin_bad_range', 'invalid version: ' + text,
             {'version': text})
    return [
        int(found.group(1)),
        0 if None is found.group(2) else int(found.group(2)),
        0 if None is found.group(3) else int(found.group(3)),
    ]


def satisfies(version, text):
    """The one satisfaction predicate: lo <= version < hi."""
    value = parse_version(version)
    span = parse_range(text)
    return 0 <= cmp(value, span['lo']) and 0 > cmp(value, span['hi'])


def satisfiesq(version, text):
    """satisfies for the internal callers that treat an unparseable
    version or range as "does not satisfy" - Capability and Graph, both of
    which run over data the corpus has already admitted."""
    try:
        return satisfies(version, text)
    except Exception:
        return False


def cmp(a, b):
    for i in range(3):
        x = a[i] if i < len(a) else 0
        y = b[i] if i < len(b) else 0
        if x != y:
            return -1 if x < y else 1
    return 0
