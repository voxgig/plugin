/// The driver (DOCS.md section 4).
///
/// Every port implements this same small thing and nothing else is
/// port-specific: the probe catalog, the command interpreter, and the
/// canonical observable.
library;

import '../lib/plugin.dart' as p;

/// A sentinel for "this command produced nothing", so a command that
/// legitimately produces nil - `export` of a missing key - still overwrites
/// the previous result.
class _Nothing {
  const _Nothing();
}

const nothing = _Nothing();

dynamic _opt(p.Inst i, String k) => p.get(i.options, k);

int _count(p.Inst i) => (i.state['count'] ?? 0) as int;

void _bump(p.Inst i, int by) => i.state['count'] = _count(i) + by;

void _declareProvides(p.Inst i) {
  for (final prov in (_opt(i, 'provides') ?? []) as List) {
    i.provides(prov);
  }
}

void _boom(p.Inst i, String callback) {
  if (callback != _opt(i, 'fail')) return;
  // `bare` raises WITHOUT a code - the ordinary library error section 12's
  // `plugin_<phase>_failed` codes exist to wrap.
  if (p.truthy(_opt(i, 'bare'))) {
    throw StateError('probe failed at $callback');
  }
  p.fail((_opt(i, 'code') ?? 'plugin_${callback}_failed') as String,
      'probe failed at $callback');
}

void _reenter(p.Inst i, String callback) {
  // A transition from inside a lifecycle callback (section 5.2).
  if (callback != _opt(i, 'reenter')) return;
  i.host.activate(i.ref);
}

/// The points every driver host declares. DOCS.md section 4.3 defines
/// `probe` as binding one hook point (`p`) and wrapping one chain point
/// (`c`), so a host without them cannot load the probe at all - they are
/// part of the contract's baseline rather than a fixture convenience. `v` is
/// the provider point the `provider` probe defaults to.
Map<String, dynamic> basePoints() => {
      'p': {'kind': 'hook'},
      'c': {'kind': 'chain', 'base': (dynamic a) => a},
      'v': {'kind': 'provider'},
    };

/// A `host` command REPLACES a base point rather than merging into it, so an
/// entry can redeclare `c` with its own base or `v` as exclusive without
/// inheriting the default's shape.
Map<String, dynamic> withPoints([dynamic extra]) {
  final out = basePoints();
  for (final k in p.sortedKeys(extra ?? {})) {
    out[k] = p.get(extra, k);
  }
  return out;
}

Map<String, dynamic> _record(String name) => {
      'name': name,
      'define': (p.Inst i) => _bump(i, 0),
      'activate': (p.Inst i) => i.acquire(),
    };

/// Section 4.3's six probes. Their behaviour is as much the contract as the
/// runner is - this is where twenty implementations of `noisy` are made to
/// fail at the same callback in the same way.
List<dynamic> probes() {
  final probe = {
    'name': 'probe',
    'define': (p.Inst i) {
      _bump(i, 0);
      final band = _opt(i, 'band');
      // One hook binding (`p`) and one chain wrap (`c`) - the workhorse
      // shape DOCS.md section 4.3 specifies. `p` RETURNS NOTHING, as the
      // canonical's arrow-with-a-block does: in `bail` mode a return is an
      // answer, and a counter that answered with its own count would make
      // every hook that keeps one un-bailable.
      i.bind('p', (next, arg) {
        _bump(i, 1);
        return null;
      }, band);
      // Wrap AFTER next, so the result spells the nesting left to right:
      // outermost first. Wrapping the ARGUMENT instead would spell it
      // backwards and make every chain expectation read wrong.
      i.bind('c', (next, v) => '${_opt(i, 'wrap') ?? ':'}${next(v)}', band);
      i.export('client', i.ref);
      // The instance api itself, so the driver's `stray` command can call
      // `release` from OUTSIDE a lifecycle callback.
      i.export('inst', i);
      _declareProvides(i);
    },
    'activate': (p.Inst i) {
      i.acquire();
      // Section 6.5: an instance that is itself a host. The outer owns the
      // inner's lifetime - registered in the scope, so it closes on
      // deactivate in the same reverse unwind as every other resource.
      final nest = _opt(i, 'nest');
      if (nest == null) return;
      final inner = i.nest({'points': withPoints()});
      for (final d in probes()) {
        inner.catalog.add(d);
      }
      for (final ref in nest as List) {
        inner.ready(ref);
      }
    },
  };

  final noisy = {
    'name': 'noisy',
    'define': (p.Inst i) {
      _bump(i, 0);
      _boom(i, 'define');
    },
    'activate': (p.Inst i) {
      // Acquire BEFORE the raise, so a failing activate has something to
      // leak if the scope does not unwind - which is the whole point of the
      // entry that asserts open == 0 afterwards.
      i.acquire();
      _reenter(i, 'activate');
      _boom(i, 'activate');
    },
    'deactivate': (p.Inst i) => _boom(i, 'deactivate'),
    'close': (p.Inst i) => _boom(i, 'close'),
  };

  final greedy = {
    'name': 'greedy',
    'define': (p.Inst i) {
      i.state['count'] = 0;
      // Section 8.1 puts resource capture in `activate`. `early` NAMES the
      // call that reaches for it in `define`, because `acquire` and
      // `release` carry the guard separately.
      if (_opt(i, 'early') == 'acquire') i.acquire();
      if (_opt(i, 'early') == 'release') i.release(() {});
    },
    'activate': (p.Inst i) {
      final n = (_opt(i, 'acquire') ?? 0) as int;
      final rel = (_opt(i, 'release') ?? 0) as int;
      final handles = List.generate(n, (_) => i.acquire());
      // Release some explicitly; the DIFFERENCE is what the instance scope
      // must unwind by itself (section 8.3), and that difference is the
      // whole test.
      for (var k = 0; k < rel && k < handles.length; k++) {
        handles[k]();
      }

      // `bind` is `early`'s counterpart for section 8.1's OTHER half.
      // Binding declaration belongs in `define`; this names the callback
      // that tries it from somewhere else.
      if (_opt(i, 'bind') == 'activate') i.bind('p', (next, arg) => null);

      // `mark` registers N FOREIGN releases - section 8.3's `release`, the
      // half `acquire` cannot exercise - each recording its own index as it
      // runs. THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
      // REVERSE UNWIND FROM A FORWARD ONE.
      i.state['unwound'] = <int>[];
      for (var k = 0; k < ((_opt(i, 'mark') ?? 0) as int); k++) {
        final at = k;
        i.release(() {
          // `markfail` makes the release RAISE - the only way section 8.3's
          // `plugin_release_failed` and its `failed` status are reachable.
          if (p.truthy(_opt(i, 'markfail'))) {
            throw StateError('release failed at $at');
          }
          (i.state['unwound'] as List).add(at);
        });
      }
    },
    // `deactivate` completes the pair: the guard is on the PHASE, not on
    // "not define", and an entry exercising only one leaves the other's
    // mutation alive.
    'deactivate': (p.Inst i) {
      if (_opt(i, 'bind') == 'deactivate') i.bind('p', (next, arg) => null);
    },
  };

  final dep = {
    'name': 'dep',
    'define': (p.Inst i) {
      i.state['count'] = 0;
      _declareProvides(i);
      final exports = _opt(i, 'exports') ?? {};
      for (final k in p.sortedKeys(exports)) {
        i.export(k, p.get(exports, k));
      }
    },
    'activate': (p.Inst i) => i.acquire(),
  };

  final provider = {
    'name': 'provider',
    'define': (p.Inst i) {
      i.state['count'] = 0;
      i.bind(
          (_opt(i, 'point') ?? 'v') as String,
          (next, arg) =>
              p.has(i.options, 'value') ? _opt(i, 'value') : i.ref,
          _opt(i, 'band'));
      _declareProvides(i);
    },
    'activate': (p.Inst i) => i.acquire(),
  };

  return [
    probe, noisy, greedy, dep, provider,
    _record('slow'), _record('other'), _record('adapter'), _record('late')
  ];
}

p.Catalog withProbes() => p.makeCatalog(probes());

/// Run a command list and return section 4.5's observable. Stops at the
/// first raise; the entry's `err` matches its code.
Map<String, dynamic> drive(List<dynamic> cmds) {
  var host = p.makeHost({'catalog': withProbes(), 'points': withPoints()});

  // Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
  // ONE. Storing it and continuing - rather than returning at the first
  // producing command - is what lets an entry emit and then inspect, which
  // most of `point` needs.
  dynamic last;

  for (final cmd in cmds) {
    try {
      final produced = doCmd(host, cmd);
      host = produced[0] as p.Host;
      if (produced[1] is! _Nothing) last = produced[1];
    } catch (e) {
      // Section 4.1: `catch` records the raise and lets the run continue,
      // which is the only way to observe a `failed` instance - section 5.2's
      // whole claim is that it stays registered and inspectable.
      if (p.get(cmd, 'catch') != true) rethrow;
    }
  }
  return host.observable(last);
}

List<dynamic> doCmd(p.Host host, dynamic cmd) {
  final ref = p.get(cmd, 'ref');
  final point = p.get(cmd, 'point') as String?;
  final spec = {
    'options': p.get(cmd, 'options'),
    'order': p.get(cmd, 'order'),
    'definition': p.get(cmd, 'definition'),
    'tag': p.get(cmd, 'tag'),
  };

  switch (p.get(cmd, 'do')) {
    case 'host':
      return [
        p.makeHost({
          'catalog': withProbes(),
          'reserved': p.get(cmd, 'reserved'),
          'keys': p.get(cmd, 'keys'),
          'defaults': p.get(cmd, 'defaults'),
          'profile': p.get(cmd, 'profile'),
          'points': withPoints(p.get(cmd, 'points')),
          // Section 11.3's strict reading. Absent means `restart`.
          'dependency': p.get(cmd, 'dependency'),
        }),
        nothing
      ];
    case 'define':
      // Section 10.1's static registration: the definition ENTERS THE
      // CATALOG here, and registration is where its option shape is
      // validated (section 9.4) - before any load, so a malformed shape
      // fails at one moment in every host rather than whenever a document
      // happens to exercise the key.
      //
      // The catalog is pre-seeded with the probe set, so re-registering a
      // probe by name is the identity this command has always been;
      // `shape` is what makes it do work. A name the probe set does not
      // hold registers a bare definition - enough to reach the catalog,
      // and never loaded.
      // Section 4.2's three keys, all of them live. `probe` names the
      // PROBE whose callbacks back the definition and `name` is what the
      // definition is called - two keys that ten entries passed as equal
      // strings, so a driver ignoring `probe` passed them all.
      final dname = p.get(cmd, 'name');
      final source = p.has(cmd, 'probe') ? p.get(cmd, 'probe') : dname;
      dynamic definition = {'name': dname};
      for (final d in probes()) {
        if (source == p.get(d, 'name')) {
          definition = Map<String, dynamic>.from(d as Map);
          definition['name'] = dname;
        }
      }
      if (p.has(cmd, 'shape')) {
        definition['shape'] = p.get(cmd, 'shape');
      }
      host.define(definition);
      return [host, nothing];
    case 'load':
      host.load(ref, spec);
      return [host, nothing];
    case 'ready':
      // declare FIRST, so the ordering block and definition reach the
      // instance - `ready` walks the staircase, it does not carry
      // configuration of its own.
      host.declare(ref, spec);
      host.ready(ref);
      return [host, nothing];
    case 'activate':
      host.activate(ref);
      return [host, nothing];
    case 'deactivate':
      host.deactivate(ref);
      return [host, nothing];
    case 'unload':
      host.unload(ref);
      return [host, nothing];
    case 'apply':
      host.apply(p.get(cmd, 'doc'), p.get(cmd, 'profile'));
      return [host, nothing];
    case 'options':
      host.options(ref, p.get(cmd, 'patch'));
      return [host, nothing];
    case 'close':
      host.close();
      return [host, nothing];
    case 'list':
      return [host, host.list()];
    case 'emit':
      return [host, host.emit(point!, p.get(cmd, 'arg'))];
    case 'chain':
      return [host, host.call(point!, p.get(cmd, 'arg'))];
    case 'provider':
      return [host, host.provider(point!, p.get(cmd, 'arg'))];
    case 'shadowed':
      return [host, host.shadowed(point!)];
    case 'export':
      return [host, host.exports(p.get(cmd, 'key') as String)];
    case 'capability':
      return [host, host.capability(p.get(cmd, 'name') as String)];
    case 'trace':
      return [host, host.trace()];
    case 'hostdeclare':
      // Section 9.1's host-owned path: the embedding host installing the
      // instance whose name it reserved.
      return [host, host.hostdeclare(ref, spec).ref];
    case 'declare':
      return [host, host.declare(ref, spec).ref];
    case 'order':
      return [host, host.order(point)];
    case 'seq':
      return [host, host.instance(ref)?.seq];
    case 'pos':
      return [host, host.instance(ref)?.pos];
    case 'inner':
      return [host, host.instance(ref)?.inner?.list()];
    case 'call':
      return _doCall(host, cmd, ref, point);
    default:
      throw StateError('unknown driver command: ${p.get(cmd, 'do')}');
  }
}

List<dynamic> _doCall(p.Host host, dynamic cmd, dynamic ref, String? point) {
  final entry = host.instance(ref);
  if (entry == null) {
    p.fail('plugin_not_loaded', 'no such instance: $ref');
  }
  switch (p.get(cmd, 'method')) {
    case 'bump':
      entry.state['count'] = ((entry.state['count'] ?? 0) as int) + 1;
      return [host, nothing];
    case 'count':
      return [host, entry.state['count'] ?? 0];
    case 'unwound':
      return [host, entry.state['unwound'] ?? []];
    case 'position':
      // Reached through the instance api, which is where section 6.6 puts it
      // - a plugin asks about itself.
      return [host, host.positionOf(ref, point!)];
    case 'stray':
      // A release from OUTSIDE a lifecycle callback. THIS BRANCH USED TO DO
      // NOTHING, and its corpus row stayed green whatever `release` did with
      // its guard.
      (host.exports('$ref/inst') as p.Inst).release(() {});
      return [host, nothing];
    default:
      return [host, nothing];
  }
}
