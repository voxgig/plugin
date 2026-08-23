"""The driver (DOCS.md section 4).

Every port implements this same small thing and nothing else is
port-specific: the probe catalog, the command interpreter, and the
canonical observable.
"""

from voxgig_plugin import PluginError, make_catalog, make_host


def probes():
    """Section 4.3's six probes. Their behaviour is as much the contract
    as the runner is - this is where twenty implementations of `noisy` are
    made to fail at the same callback in the same way."""

    def record(name):
        return {
            'name': name,
            'define': lambda i: i.state.__setitem__(
                'count', i.state.get('count') or 0),
            'activate': lambda i: i.acquire(),
        }

    def probe_define(i):
        i.state['count'] = i.state.get('count') or 0
        band = i.options.get('band')
        # One hook binding (`p`) and one chain wrap (`c`) - the workhorse
        # shape DOCS.md section 4.3 specifies.
        i.bind('p', lambda _arg=None: bump(i), band)
        # Wrap AFTER next, so the result spells the nesting left to right:
        # outermost first. Wrapping the ARGUMENT instead would spell it
        # backwards and make every chain expectation read wrong.
        i.bind('c', lambda nxt, v: (i.options.get('wrap') or ':') +
               str(nxt(v)), band)
        i.export('client', i.ref)
        # The instance api itself, so the driver's `stray` command can
        # call `release` from OUTSIDE a lifecycle callback.
        i.export('inst', i)
        declareprovides(i)

    def bump(i):
        i.state['count'] = (i.state.get('count') or 0) + 1

    def probe_activate(i):
        i.acquire()
        # Section 6.5: an instance that is itself a host. The outer owns
        # the inner's lifetime - registered in the scope, so it closes on
        # deactivate in the same reverse unwind as every other resource.
        nest = i.options.get('nest')
        if not nest:
            return
        inner = i.nest({'points': withpoints()})
        for definition in probes():
            inner.catalog.add(definition)
        for ref in nest:
            inner.ready(ref)

    probe = {'name': 'probe', 'define': probe_define,
             'activate': probe_activate}

    def noisy_activate(i):
        # Acquire BEFORE the raise, so a failing activate has something to
        # leak if the scope does not unwind - which is the whole point of
        # the entry that asserts open == 0 afterwards.
        i.acquire()
        reenter(i, 'activate')
        boom(i, 'activate')

    def noisy_define(i):
        i.state['count'] = i.state.get('count') or 0
        boom(i, 'define')

    noisy = {
        'name': 'noisy',
        'define': noisy_define,
        'activate': noisy_activate,
        'deactivate': lambda i: boom(i, 'deactivate'),
        'close': lambda i: boom(i, 'close'),
    }

    def greedy_activate(i):
        n = i.options.get('acquire') or 0
        rel = i.options.get('release') or 0
        handles = [i.acquire() for _ in range(n)]
        # Release some explicitly; the DIFFERENCE is what the instance
        # scope must unwind by itself (section 8.3), and that difference
        # is the whole test.
        for k in range(min(rel, len(handles))):
            handles[k]()

        # `mark` registers N FOREIGN releases - section 8.3's `release`,
        # the half `acquire` cannot exercise - each recording its own
        # index as it runs.
        #
        # THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A REVERSE
        # UNWIND FROM A FORWARD ONE. An acquired handle is an idempotent
        # counter decrement, so running them in either direction leaves
        # the same `open`.
        i.state['unwound'] = []
        for k in range(i.options.get('mark') or 0):
            i.release(lambda k=k: markrelease(i, k))

    def greedy_define(i):
        i.state['count'] = 0
        # Section 8.1 puts resource capture in `activate`. `early` NAMES
        # the call that reaches for it in `define`, because `acquire` and
        # `release` carry the guard separately.
        if 'acquire' == i.options.get('early'):
            i.acquire()
        if 'release' == i.options.get('early'):
            i.release(lambda: None)

    greedy = {
        'name': 'greedy',
        'define': greedy_define,
        'activate': greedy_activate,
    }

    def dep_define(i):
        i.state['count'] = 0
        declareprovides(i)
        for key in sorted(i.options.get('exports') or {}):
            i.export(key, i.options['exports'][key])

    dep = {'name': 'dep', 'define': dep_define,
           'activate': lambda i: i.acquire()}

    def provider_define(i):
        i.state['count'] = 0
        point = i.options.get('point') or 'v'
        i.bind(point,
               lambda *_a: (i.options['value'] if 'value' in i.options
                            else i.ref),
               i.options.get('band'))
        declareprovides(i)

    provider = {'name': 'provider', 'define': provider_define,
                'activate': lambda i: i.acquire()}

    return [probe, noisy, greedy, dep, provider,
            record('slow'), record('other'), record('adapter'),
            record('late')]


def markrelease(i, k):
    """`markfail` makes the release RAISE - the only way section 8.3's
    `plugin_release_failed` and its `failed` status are reachable."""
    if i.options.get('markfail'):
        raise Exception('release failed at ' + str(k))
    i.state['unwound'].append(k)


def declareprovides(i):
    for prov in i.options.get('provides') or []:
        i.provides(prov)


def boom(i, callback):
    if callback == i.options.get('fail'):
        # `bare` raises WITHOUT a code - the ordinary library error
        # section 12's `plugin_<phase>_failed` codes exist to wrap.
        if i.options.get('bare'):
            raise Exception('probe failed at ' + callback)
        raise PluginError(i.options.get('code') or ('plugin_' + callback +
                                                    '_failed'),
                          'probe failed at ' + callback)


def reenter(i, callback):
    if callback == i.options.get('reenter'):
        # A transition from inside a lifecycle callback (section 5.2).
        i.host().activate(i.ref)


def basepoints():
    """The points every driver host declares. DOCS.md section 4.3 defines
    `probe` as binding one hook point (`p`) and wrapping one chain point
    (`c`), so a host without them cannot load the probe at all - they are
    part of the contract's baseline rather than a fixture convenience.
    `v` is the provider point the `provider` probe defaults to."""
    return {
        'p': {'kind': 'hook'},
        'c': {'kind': 'chain', 'base': lambda *a: a[0] if 0 < len(a) else None},
        'v': {'kind': 'provider'},
    }


def withpoints(extra=None):
    out = basepoints()
    for key in extra or {}:
        # A `host` command REPLACES a base point rather than merging into
        # it, so an entry can redeclare `c` with its own base or `v` as
        # exclusive without inheriting the default's shape.
        out[key] = extra[key]
    return out


def withprobes():
    return make_catalog(probes())


# A sentinel for "this command produced nothing", so a command that
# legitimately produces `None` - `export` of a missing key - still
# overwrites the previous result.
NOTHING = object()


def drive(cmds):
    """Run a command list and return section 4.5's observable. Stops at
    the first raise; the entry's `err` matches its code."""
    host = make_host({'catalog': withprobes(), 'points': withpoints()})

    # Section 4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES
    # ONE. Storing it and continuing - rather than returning at the first
    # producing command - is what lets an entry emit and then inspect,
    # which most of `point` needs.
    last = None

    for cmd in cmds:
        try:
            host, value = docmd(host, cmd)
            if NOTHING is not value:
                last = value
        except Exception:
            # Section 4.1: `catch` records the raise and lets the run
            # continue, which is the only way to observe a `failed`
            # instance - section 5.2's whole claim is that it stays
            # registered and inspectable.
            if True is not cmd.get('catch'):
                raise
    return host.observable(last)


def docmd(host, cmd):
    verb = cmd.get('do')
    ref = cmd.get('ref')
    point = cmd.get('point')
    spec = {'options': cmd.get('options'), 'order': cmd.get('order'),
            'definition': cmd.get('definition'), 'tag': cmd.get('tag')}

    if 'host' == verb:
        return make_host({
            'catalog': withprobes(),
            'reserved': cmd.get('reserved'), 'keys': cmd.get('keys'),
            'defaults': cmd.get('defaults'), 'profile': cmd.get('profile'),
            'points': withpoints(cmd.get('points')),
            # Section 11.3's strict reading. Absent means `restart`, which
            # is the default precisely because a station that cannot swap
            # a provider without a restart has lost the argument for
            # having a plugin system.
            'dependency': cmd.get('dependency'),
        }), NOTHING

    if 'define' == verb:
        # The catalog is pre-seeded with the probe set; `define` names
        # which entry backs this definition.
        return host, NOTHING

    if 'load' == verb:
        host.load(ref, spec)
        return host, NOTHING
    if 'ready' == verb:
        # declare FIRST, so the ordering block and definition reach the
        # instance - `ready` walks the staircase, it does not carry
        # configuration of its own.
        host.declare(ref, spec)
        host.ready(ref)
        return host, NOTHING
    if 'activate' == verb:
        host.activate(ref)
        return host, NOTHING
    if 'deactivate' == verb:
        host.deactivate(ref)
        return host, NOTHING
    if 'unload' == verb:
        host.unload(ref)
        return host, NOTHING
    if 'apply' == verb:
        host.apply(cmd.get('doc'), cmd.get('profile'))
        return host, NOTHING
    if 'options' == verb:
        host.options(ref, cmd.get('patch'))
        return host, NOTHING
    if 'close' == verb:
        host.close()
        return host, NOTHING

    if 'list' == verb:
        return host, host.list()
    if 'emit' == verb:
        return host, host.emit(point, cmd.get('arg'))
    if 'chain' == verb:
        return host, host.call(point, cmd.get('arg'))
    if 'provider' == verb:
        return host, host.provider(point, cmd.get('arg'))
    if 'shadowed' == verb:
        return host, host.shadowed(point)
    if 'export' == verb:
        return host, host.exports(cmd.get('key'))
    if 'capability' == verb:
        return host, host.capability(cmd.get('name'))
    if 'trace' == verb:
        return host, host.trace()
    if 'hostdeclare' == verb:
        # Section 9.1's host-owned path: the embedding host installing
        # the instance whose name it reserved.
        return host, host.hostdeclare(ref, spec)['ref']
    if 'declare' == verb:
        return host, host.declare(ref, spec)['ref']
    if 'order' == verb:
        return host, host.order(point)

    if 'seq' == verb:
        entry = host.instance(ref)
        return host, (entry['seq'] if entry else None)
    if 'pos' == verb:
        entry = host.instance(ref)
        return host, (entry['pos'] if entry else None)
    if 'inner' == verb:
        entry = host.instance(ref)
        return host, (entry['inner'].list()
                      if entry and entry['inner'] else None)

    if 'call' == verb:
        return docall(host, cmd, ref, point)

    raise Exception('unknown driver command: ' + str(verb))


def docall(host, cmd, ref, point):
    entry = host.instance(ref)
    if not entry:
        raise PluginError('plugin_not_loaded', 'no such instance: ' + str(ref))
    method = cmd.get('method')
    if 'bump' == method:
        entry['state']['count'] = (entry['state'].get('count') or 0) + 1
        return host, NOTHING
    if 'count' == method:
        return host, (entry['state'].get('count') or 0)
    if 'unwound' == method:
        return host, (entry['state'].get('unwound') or [])
    if 'position' == method:
        # Reached through the instance api, which is where section 6.6
        # puts it - a plugin asks about itself.
        return host, host.positionof(ref, point)
    if 'stray' == method:
        # A release from OUTSIDE a lifecycle callback. THIS BRANCH USED
        # TO DO NOTHING, and its corpus row stayed green whatever
        # `release` did with its guard.
        host.exports(ref + '/inst').release(lambda: None)
        return host, NOTHING
    return host, NOTHING
