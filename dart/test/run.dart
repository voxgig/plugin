/// The whole suite: pure sections by direct call, driver sections by command
/// list, and a coverage guard above both.
///
/// A plain runner rather than `package:test`, for the same reason the port
/// has no pubspec dependencies: a conformance suite whose only job is to run
/// one corpus and report which entries disagree does not need a framework,
/// and adding one would make `make test` depend on a `dart pub get` nobody
/// else in this repo has.
library;

import 'dart:io';

import '../lib/plugin.dart' as p;
import 'corpus.dart' as corpus;
import 'driver.dart' as driver;

final failures = <String>[];
var ranSections = 0;
var ranEntries = 0;

const pureSections = [
  'ref', 'env', 'version', 'capability', 'graph', 'resolve', 'config'
];
const driverSections = [
  'lifecycle', 'order', 'point', 'export', 'depend',
  'declare', 'state', 'resource', 'nest', 'trace', 'apply', 'error'
];

dynamic _in(dynamic e) => p.get(e, 'in');
dynamic _arg(dynamic e, int i) {
  final args = (p.get(e, 'args') ?? []) as List;
  return i < args.length ? args[i] : null;
}

/// Dispatch every group, and fail on a group the runner does not know - a
/// group silently not run is worse than a failure.
void runSection(dynamic spec, String name,
    dynamic Function(dynamic)? Function(String) subjectFor) {
  final groups = corpus.section(spec, name);
  ranSections++;
  for (final group in groups.keys.toList()..sort()) {
    final fn = subjectFor(group);
    if (fn == null) {
      failures.add('$name: corpus group with no subject: $group');
      continue;
    }
    final set = groups[group]!;
    for (var i = 0; i < set.length; i++) {
      ranEntries++;
      final why = corpus.check(set[i], fn);
      if (why != null) {
        failures.add('$name/${corpus.label(group, i, set[i])}: $why');
      }
    }
  }
}

/// The common case: a group name selects the subject directly.
void runMapped(dynamic spec, String name,
        Map<String, dynamic Function(dynamic)> subjects) =>
    runSection(spec, name, (group) => subjects[group]);

void main() {
  final spec = corpus.corpus();

  runMapped(spec, 'ref', {
    'parse': (e) => p.parseRef(_in(e)),
    'parsebad': (e) => p.parseRef(_in(e)),
    'format': (e) => p.formatRef(_arg(e, 0), _arg(e, 1)),
    'formatbad': (e) => p.formatRef(_arg(e, 0), _arg(e, 1)),
    'canon': (e) => p.canonRef(_in(e)),
    'name': (e) => p.checkName(_in(e)),
    'tag': (e) => p.checkTag(_in(e)),
    'bound': (e) => p.checkName(_in(e)),
    'boundtag': (e) => p.checkTag(_in(e)),
  });

  dynamic env(dynamic e) => p.applyEnv(_in(e));
  runMapped(spec, 'env', {
    'option': env, 'value': env, 'toggle': env,
    'profile': env, 'ambiguous': env, 'reserved': env,
  });

  dynamic rng(dynamic e) => p.parseRange(_in(e));
  runMapped(spec, 'version', {
    'range': rng,
    'rangebad': rng,
    'satisfies': (e) =>
        p.satisfies(p.get(_in(e), 'version'), p.get(_in(e), 'range')),
  });

  dynamic cap(dynamic e) =>
      p.resolveCapability(p.get(_in(e), 'req'), p.get(_in(e), 'candidates'));
  runMapped(spec, 'capability', {'match': cap, 'nested': cap, 'rank': cap});

  dynamic graph(dynamic e) => p.resolveGraph(_in(e));
  runMapped(spec, 'graph', {'resolve': graph, 'blocked': graph});

  runMapped(spec, 'resolve', {
    'candidates': (e) =>
        p.resolveCandidates(p.get(_in(e), 'name') as String,
            p.get(_in(e), 'sources')),
    'from': (e) => p.resolveFrom(_in(e)),
  });

  // `config` picks its subject by group PREFIX rather than by name, because
  // the two functions split the section cleanly.
  runSection(spec, 'config', (group) {
    if (group.startsWith('norm')) return (e) => p.normalizeConfig(_in(e));
    if (group.startsWith('opt')) return (e) => p.resolveOptions(_in(e));
    return null;
  });

  for (final name in driverSections) {
    runSection(spec, name, (_) => (e) => driver.drive(p.get(e, 'in') as List));
  }

  // EVERY CORPUS SECTION IS RUN. The per-section dispatch already fails on a
  // GROUP with no subject; this closes the level above, because a whole
  // SECTION the runner never mentions is a section silently not run.
  final primary = p.get(spec, 'primary') ?? {};
  final ran = [...pureSections, ...driverSections];

  // The corpus metadata block is what turns on strict entry validation in
  // every runner, so a corpus that lost it must not silently downgrade this
  // port's checking.
  if (p.get(p.get(spec, 'PLUGIN') ?? {}, 'version') != 1) {
    failures.add('corpus PLUGIN.version must be 1');
  }

  final missing =
      p.sortedKeys(primary).where((n) => !ran.contains(n)).toList()..sort();
  if (missing.isNotEmpty) {
    failures.add('corpus sections no test runs: ${missing.join(', ')}');
  }
  final extra = ran.where((n) => !p.has(primary, n)).toList()..sort();
  if (extra.isNotEmpty) {
    failures.add(
        'tests name sections the corpus does not have: ${extra.join(', ')}');
  }

  // A floor, not a fixture: the corpus grows, and a run that suddenly covers
  // a fraction of it is the failure worth catching.
  if (ranEntries < 400) {
    failures.add('only $ranEntries corpus entries reachable');
  }

  if (failures.isEmpty) {
    print('dart: $ranEntries corpus entries across $ranSections sections, '
        'all pass');
    exit(0);
  }
  for (final f in failures) {
    stderr.writeln(f);
  }
  stderr.writeln('\ndart: ${failures.length} failure(s) of $ranEntries entries');
  exit(1);
}
