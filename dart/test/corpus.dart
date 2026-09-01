/// The corpus runner.
///
/// Reads spec/plugin.json - the COMMITTED artifact, not the aontu source -
/// exactly as every other port's runner does. No port needs a Node
/// toolchain to run its tests, and this one does not get a private door into
/// the source either.
///
/// A group name selects the subject. That is the whole dispatch, and it is
/// deliberately dumb: a runner that inferred the subject from the entry's
/// shape would silently run the wrong function when an entry was mistyped.
library;

import 'dart:convert';
import 'dart:io';

import '../lib/plugin.dart' as p;

/// A sentinel for "this key was not present". A dart map returns null for
/// both an absent key and a JSON null, and `__UNDEF__` and `__NULL__` are
/// different assertions.
class Missing {
  const Missing();
}

const missing = Missing();

dynamic corpus() =>
    jsonDecode(File('../spec/plugin.json').readAsStringSync());

Map<String, List<dynamic>> section(dynamic spec, String name) {
  final sec = p.get(p.get(spec, 'primary') ?? {}, name);
  if (sec == null) throw StateError('no such corpus section: $name');

  final out = <String, List<dynamic>>{};
  for (final group in p.sortedKeys(sec)) {
    if (group == 'DEF') continue;
    final body = p.get(sec, group);
    if (body is! Map || p.get(body, 'set') is! List) continue;
    out[group] = p.get(body, 'set') as List<dynamic>;
  }
  return out;
}

/// A stable label, so a failure names the entry rather than an index.
String label(String group, int i, dynamic entry) =>
    (p.get(entry, 'id') ?? '$group#$i') as String;

/// Deep equality over spec values. Key order never matters; list order
/// always does.
///
/// AGENTS.md section 1: "The plugin library must never be used to implement
/// its own tests." A shared comparison lets a broken implementation and its
/// oracle be wrong together and stay green, so the corpus's equality is
/// written here rather than imported.
bool same(dynamic a, dynamic b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final k in a.keys) {
      if (!b.containsKey(k) || !same(a[k], b[k])) return false;
    }
    return true;
  }
  if (a is List || b is List) {
    if (a is! List || b is! List || a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!same(a[i], b[i])) return false;
    }
    return true;
  }
  if (a is Map || b is Map) return false;
  return a == b;
}

/// Partial match: every key the expectation names must agree, and keys it
/// does not name are ignored. `__EXISTS__` asserts presence without pinning
/// a value; `/re/` matches a string as a regular expression.
bool matches(dynamic expect, dynamic actual) {
  if (expect == '__EXISTS__') return actual is! Missing && actual != null;
  if (expect == '__UNDEF__') return actual is Missing;
  if (expect == '__NULL__') return actual is! Missing && actual == null;

  if (actual is Missing) actual = null;

  if (expect is String &&
      expect.length > 2 &&
      expect.startsWith('/') &&
      expect.endsWith('/')) {
    if (actual is! String) return false;
    return RegExp(expect.substring(1, expect.length - 1)).hasMatch(actual);
  }

  if (expect is List) {
    if (actual is! List || expect.length != actual.length) return false;
    for (var i = 0; i < expect.length; i++) {
      if (!matches(expect[i], actual[i])) return false;
    }
    return true;
  }

  if (expect is Map) {
    if (actual is! Map) return false;
    // The oracle's own key walk: `sortedKeys` is behaviour the corpus
    // checks, so it does not get to decide which keys the oracle reads
    // (AGENTS.md section 1). Order is irrelevant - every named key must
    // match, so this is a conjunction.
    for (final k in expect.keys) {
      if (!matches(expect[k], actual.containsKey(k) ? actual[k] : missing)) {
        return false;
      }
    }
    return true;
  }

  return same(expect, actual);
}

/// Run one entry against a subject and report the disagreement, if any.
///
/// The three combinations the spec format allows are enforced here as well
/// as at build time, because a runner that quietly accepted `err` beside
/// `out` would let a contradictory entry pass.
String? check(dynamic entry, dynamic Function(dynamic) subject) {
  if (p.has(entry, 'err') && p.has(entry, 'out')) {
    return 'entry has both err and out';
  }

  dynamic value;
  Object? raised;
  try {
    value = subject(entry);
  } catch (e) {
    raised = e;
  }

  if (p.has(entry, 'err')) {
    if (raised == null) return 'expected a raise, got: ${p.encode(value)}';

    // Errors compare by CODE (section 12). Message wording is a port's own
    // business, and pinning it would make every translation a corpus change.
    final want = p.get(entry, 'err');
    final got = p.codeOf(raised);
    if (want != true && got != want) {
      return 'expected code $want, got $got (${p.messageOf(raised)})';
    }
    if (p.has(entry, 'match')) {
      final shown = {
        'err': {
          'code': got,
          'message': p.messageOf(raised),
          'name': 'PluginError'
        }
      };
      if (!matches(p.get(entry, 'match'), shown)) {
        return 'error did not match ${p.encode(p.get(entry, 'match'))}, '
            'got ${p.encode(shown)}';
      }
    }
    return null;
  }

  if (raised != null) {
    return 'unexpected raise: ${p.codeOf(raised)} ${p.messageOf(raised)}';
  }

  if (p.has(entry, 'out') && !same(p.get(entry, 'out'), value)) {
    return 'expected ${p.encode(p.get(entry, 'out'))}, got ${p.encode(value)}';
  }

  if (p.has(entry, 'match')) {
    final shown = {'in': p.get(entry, 'in'), 'out': value};
    if (!matches(p.get(entry, 'match'), shown)) {
      return 'did not match ${p.encode(p.get(entry, 'match'))}, '
          'got out=${p.encode(value)}';
    }
  }

  if (!p.has(entry, 'out') && !p.has(entry, 'match')) {
    return 'entry asserts nothing';
  }
  return null;
}
