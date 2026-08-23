"""The host: the lifecycle state machine (section 5), extension points
(section 6), and resource capture (section 8).

TWO RULES SHAPE EVERY METHOD BELOW.

Transitions are SEQUENTIAL (section 5.2). One at a time, in call order,
never interleaved; a transition triggered from inside a lifecycle callback
is `plugin_reentrant`. A hard rule, because it is the only way the
semantics can be identical in Go, in Ruby and in single-threaded
JavaScript.

Reconciliation is EAGER (section 18's portability budget). A transition
settles by running the state machine to a fixed point, not by suspending
on a promise. Every port must be able to do the same, and fourteen of them
will not have JavaScript's event loop.
"""

from .types import fail
from .ref import canon_ref, format_ref, parse_ref
from .catalog import make_catalog
from .order import resolve_order
from .point import emit as fanout, compose, provider as pickone
from .export import resolve_export
from .capability import resolve_capability
from .config import normalize_config, resolve_options
from .depend import checkcycle, gatesactivation, requirements, restartsonloss


def make_host(options=None):
    return Host(options)


class Inst:
    """What a definition's callbacks see. Deliberately not the internal
    record: a plugin that could reach `status` could also write it."""

    def __init__(self, host, entry):
        self._host = host
        self._entry = entry
        self.ref = entry['ref']
        self.name = parse_ref(entry['ref'])['name']
        self.tag = parse_ref(entry['ref'])['tag']

    @property
    def options(self):
        return self._entry['options']

    @property
    def state(self):
        return self._entry['state']

    def host(self):
        return self._host

    def release(self, fn):
        """Foreign resources the host did not hand out are registered
        explicitly (section 8.3); host calls are recorded automatically.

        SYMMETRIC WITH `acquire`, and it has to be: `open` counts the
        resources CURRENTLY HELD, so an entry that is registered and then
        unwound must leave the count where it found it.
        """
        if not self._host._intransition:
            fail('plugin_release_scope', 'release called outside activate')
        host = self._host
        done = [False]

        def unwrap():
            if not done[0]:
                done[0] = True
                host._open -= 1
                fn()

        self._entry['scope'].append(unwrap)
        host._open += 1

    def acquire(self):
        """The synthetic counter the driver owns, so "what is open" is
        data rather than an assertion each port words differently.

        Returns its own release, so a plugin can hand one back early. The
        scope still holds the entry and unwinding it twice is a no-op -
        releasing early must not make teardown wrong.
        """
        if not self._host._intransition:
            fail('plugin_release_scope', 'acquire called outside activate')
        host = self._host
        done = [False]

        def rel():
            if not done[0]:
                done[0] = True
                host._open -= 1

        self._entry['scope'].append(rel)
        host._open += 1
        return rel

    def bind(self, point, fn, band=None):
        """Bind into a host point. Declared in `define`; the host inserts
        it only after `activate` returns successfully (section 8.1), which
        is why a failing activate leaves no live binding behind."""
        if point not in self._host._points:
            fail('plugin_point_unknown', 'no such point: ' + point,
                 {'point': point})
        self._entry['bindings'].append(
            {'ref': self.ref, 'point': point, 'fn': fn, 'band': band or 0})

    def export(self, key, value):
        """Published for other plugins and for the application (section
        11)."""
        self._entry['exports'][key] = value

    def provides(self, prov):
        """What this instance can do for others (section 11.1)."""
        self._entry['provides'].append(prov)

    def position(self, point):
        """Where this binding landed (section 6.6) - the plugin-side
        counterpart to a host pin. Station found that a plugin can need to
        KNOW it is in the right place: its middleware must sit immediately
        outside the base transport or its "wire truth" events are fiction.

        THE HOST DOES NOT POLICE THIS; it just makes the fact available. A
        plugin that requires a position it did not get fails loudly rather
        than reporting nonsense - and that is the plugin's call, because
        only it knows what its position means. Verification tells a plugin
        it was misplaced; a pin (section 7) stops the misplacement from
        being expressible at all. The two are not substitutes.
        """
        return self._host.positionof(self.ref, point)

    def nest(self, nestopts=None):
        """AN INSTANCE MAY ITSELF BE A HOST (section 6.5), and THE OUTER
        ONE OWNS THE INNER ONE'S LIFETIME. Registering the teardown in the
        instance scope is what makes that true rather than aspirational:
        the inner host closes when the outer instance deactivates, in the
        same reverse unwind as every other resource."""
        if not self._host._intransition:
            fail('plugin_release_scope',
                 'nest called outside a lifecycle callback')
        inner = Host(nestopts)
        self._entry['scope'].append(lambda: inner.close())
        self._entry['inner'] = inner
        return inner


class Host:
    def __init__(self, options=None):
        self._opts = options or {}
        self._dependency = self._opts.get('dependency') or 'restart'
        # Set for the duration of a bulk teardown, so `_held` knows this
        # is a coordinated operation rather than an ad-hoc deactivation.
        self._coordinated = False

        self.catalog = self._opts.get('catalog') or make_catalog()
        self._reserved = self._opts.get('reserved') or []
        self._points = self._opts.get('points') or {}

        self._inst = {}
        self._log = []
        # Section 14: the lifecycle event record. `seq` distinguishes ONE
        # INCARNATION of stripe$test from the next, which is the whole
        # reason it is not `pos` (section 4 rule 4).
        self._events = []
        self._seqn = 0
        self._open = 0
        self._intransition = False

    # --- observation --------------------------------------------------

    def list(self):
        """Introspection NEVER advances the state (section 5.2). A status
        page must not be a way to accidentally import twenty packages."""
        return {r: self._inst[r]['status'] for r in sorted(self._inst)}

    def instance(self, ref):
        return self._inst.get(canon_ref(ref))

    def trace(self):
        return list(self._events)

    def observable(self, result=None):
        return {
            'status': self.list(),
            'open': self._open,
            'log': list(self._log),
            'result': None if None is result else result,
        }

    # --- the state machine --------------------------------------------

    def _guard(self):
        if self._intransition:
            fail('plugin_reentrant',
                 'transition attempted from inside a lifecycle callback')

    def _need(self, ref):
        r = canon_ref(ref)
        entry = self._inst.get(r)
        if not entry:
            fail('plugin_not_loaded', 'no such instance: ' + r, {'ref': r})
        return entry

    def _checkreserved(self, ref):
        if 0 == len(self._reserved):
            return
        if parse_ref(ref)['name'] in self._reserved:
            fail('plugin_ref_reserved', 'ref is reserved by the host: ' + ref,
                 {'ref': ref})

    def _run(self, entry, callback, phase):
        fn = entry['def'].get(callback)
        self._log.append(entry['ref'] + ':' + phase)
        self._events.append({'ref': entry['ref'], 'event': phase,
                             'seq': entry['seq'], 'status': entry['status']})
        if not callable(fn):
            return
        self._intransition = True
        try:
            fn(Inst(self, entry))
        finally:
            self._intransition = False

    def autotag(self, name):
        """AUTO-TAGGING IS EXPLICIT (section 4 rule 3).
        `declare('stripe', {'tag': '?'})` assigns the LOWEST UNUSED
        POSITIVE INTEGER tag and returns the assigned pair. Without `'?'`,
        a collision is an error.

        It needs a host because it must know what is already declared,
        which is why it cannot live in the pure `ref` section - the
        correction P1.7 made to section 15.3.
        """
        n = 1
        while True:
            cand = format_ref(name, str(n))
            if cand not in self._inst:
                return cand
            n += 1

    def declare(self, ref, spec=None):
        spec = spec or {}
        if '?' == spec.get('tag'):
            ref = self.autotag(parse_ref(canon_ref(ref))['name'])
        r = canon_ref(ref)
        self._checkreserved(r)
        defname = spec.get('definition') or parse_ref(r)['name']
        definition = self.catalog.get(defname)
        if not definition:
            fail('plugin_unknown_definition', 'not in catalog: ' + defname,
                 {'name': defname})

        existing = self._inst.get(r)
        if existing:
            # Section 4 rule 1: a pair addresses at most one instance.
            # Re-declaring the SAME definition is the idempotent case; a
            # different one is a duplicate, not a silent overwrite
            # (seneca) and not an impossibility (sdkgen).
            if existing['def']['name'] != definition['name']:
                fail('plugin_ref_duplicate',
                     'instance already declared: ' + r, {'ref': r})
            return existing

        entry = {
            'ref': r, 'def': definition, 'status': 'declared',
            'pos': len(self._inst) if None is spec.get('pos') else spec['pos'],
            'seq': self._seqn,
            'options': spec.get('options') or {},
            'state': {}, 'order': spec.get('order'), 'unmet': [], 'scope': [],
            'bindings': [], 'exports': {}, 'provides': [], 'inner': None,
        }
        self._seqn += 1
        self._inst[r] = entry
        return entry

    def load(self, ref, spec=None):
        self._guard()
        spec = spec or {}
        entry = self.declare(ref, spec)
        if 'declared' != entry['status']:
            return entry            # idempotent in the trivial direction
        if spec.get('options'):
            entry['options'] = spec['options']
        try:
            self._run(entry, 'define', 'define')
        except Exception:
            entry['status'] = 'failed'
            raise
        entry['status'] = 'loaded'

        # AT LOAD, and before anything runs: a cycle through
        # restart-causing requirements does not settle, and the only safe
        # time to report a non-terminating reconcile is before it starts
        # (section 11.3). `provides` is populated by `define`, which has
        # just run, so this is the first moment the graph is complete.
        try:
            checkcycle(self._graphnodes())
        except Exception:
            entry['status'] = 'failed'
            raise
        return entry

    def _graphnodes(self):
        """The requirement graph as plain data, for the pure detector."""
        return [
            {'ref': r,
             'provides': [p['name'] for p in self._inst[r]['provides']],
             'requires': requirements(self._inst[r]['options'])}
            for r in sorted(self._inst)
        ]

    def activate(self, ref):
        self._guard()
        entry = self._need(ref)
        if 'live' == entry['status']:
            return entry                  # no-op returning success
        if 'failed' == entry['status']:
            fail('plugin_bad_state', 'instance has failed: ' + entry['ref'],
                 {'ref': entry['ref']})
        if 'declared' == entry['status']:
            self.load(entry['ref'])

        # A declared requirement that is not live means `pending`:
        # activation is a STANDING REQUEST, not a one-shot event.
        unmet = self._unmetof(entry)
        if 0 < len(unmet):
            entry['unmet'] = unmet
            entry['status'] = 'pending'
            return entry

        try:
            self._run(entry, 'activate', 'activate')
        except Exception:
            # Unwind whatever the partial activation captured, in reverse.
            self._unwind(entry)
            entry['status'] = 'failed'
            raise
        entry['status'] = 'live'
        self._reconcile()
        return entry

    def deactivate(self, ref):
        self._guard()
        entry = self._need(ref)
        if entry['status'] in ('loaded', 'declared'):
            return entry

        if 'pending' == entry['status']:
            # DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (section
            # 5.2). It never reached activate, so it holds no scope and no
            # live bindings; running the definition's deactivate there
            # would be teardown without matching setup, which plugins are
            # not written to survive and which could fail an instance that
            # had done nothing wrong. It cannot fail.
            entry['status'] = 'loaded'
            entry['unmet'] = []
            return entry

        self._held(entry)
        self._cascade(entry, {})

        try:
            self._run(entry, 'deactivate', 'deactivate')
        except Exception:
            self._unwind(entry)
            entry['status'] = 'failed'
            raise
        self._unwind(entry)
        entry['status'] = 'loaded'
        self._reconcile()
        return entry

    def unload(self, ref):
        self._guard()
        entry = self._need(ref)
        if entry['status'] in ('live', 'pending'):
            if 'live' == entry['status']:
                self._held(entry)
                self._cascade(entry, {})
                try:
                    self._run(entry, 'deactivate', 'deactivate')
                except Exception:
                    # Section 5.2: ANY failure during a transition lands
                    # the instance in `failed`, with the scope STILL FULLY
                    # UNWOUND - and the instance STAYS REGISTERED, because
                    # `failed` is a state an operator has to be able to
                    # see.
                    self._unwind(entry)
                    entry['status'] = 'failed'
                    raise
                self._unwind(entry)
            entry['status'] = 'loaded'
        if entry['status'] in ('loaded', 'failed'):
            try:
                self._run(entry, 'close', 'close')
            finally:
                del self._inst[entry['ref']]
            return
        del self._inst[entry['ref']]

    def ready(self, ref):
        """Runs the whole forward path in one call (section 5.1). Section
        15.2's verb list omits this; 5.1 defines it and 15.3's `declare`
        row requires the corpus to pin it, so the list was incomplete
        rather than excluding it (DOCS.md section 4.2)."""
        self._guard()
        r = canon_ref(ref)
        if r not in self._inst:
            self.declare(r)
        if 'declared' == self._inst[r]['status']:
            self.load(r)
        return self.activate(r)

    def _unwind(self, entry):
        """Bindings go live only when activation succeeds (section 8.1),
        so the teardown is the exact inverse: reverse order, always."""
        for i in range(len(entry['scope']) - 1, -1, -1):
            try:
                entry['scope'][i]()
            except Exception:
                pass    # a failing release is section 12's problem
        entry['scope'] = []

    def _unmetof(self, entry):
        """A REQUIREMENT IS ON A CAPABILITY, not on a ref (section 11.1) -
        it is a dependency on something that can do the job, and which
        instance is doing it is exactly the configuration detail a plugin
        must not care about. A bare string is shorthand for `{name}`.

        A ref satisfies too, because a host that genuinely needs a
        specific instance should not have to invent a capability for it.
        """
        return [
            req['name'] for req in requirements(entry['options'])
            if gatesactivation(req) and 0 == len(self._providersof(req))
        ]

    def _boundproviders(self, entry):
        """The instance currently SELECTED for each of this one's
        restart-causing requirements. A BINDING IS TO AN INSTANCE, not to
        a capability (section 11.1), and that is what decides behaviour
        when the bound provider leaves while another match remains: the
        selected one going away restarts a `static` consumer even though a
        survivor is available. It is not silently re-pointed - `static` is
        the plugin saying in writing that it cannot survive a provider
        swap, and a survivor being available does not make the swap
        survivable."""
        out = []
        for req in requirements(entry['options']):
            if not restartsonloss(req):
                continue
            cands = self._providersof(req)
            if 0 < len(cands) and cands[0]['ref'] not in out:
                out.append(cands[0]['ref'])
        return out

    def _consumersof(self, ref):
        """Live instances whose selected provider is `ref` and which would
        be restarted by losing it."""
        return [
            r for r in sorted(self._inst)
            if r != ref and 'live' == self._inst[r]['status']
            and ref in self._boundproviders(self._inst[r])
        ]

    def _providersof(self, req):
        cands = []
        try:
            want = canon_ref(req['name'])
        except Exception:
            want = req['name']
        for ref in sorted(self._inst):
            target = self._inst[ref]
            if 'live' != target['status']:
                continue
            # A ref satisfies directly.
            if ref == want:
                cands.append({'ref': ref, 'pos': target['pos'],
                              'provides': {'name': req['name']}})
                continue
            for prov in target['provides']:
                if prov.get('name') == req['name']:
                    cands.append({'ref': ref, 'pos': target['pos'],
                                  'provides': prov})
        return resolve_capability(req, cands)

    def _cascade(self, provider, seen):
        """CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (section 11.3).

        The cascade is part of the provider's own deactivation and runs
        BEFORE the provider's `deactivate` callback and scope unwind, so a
        consumer's teardown can still call the thing it depends on -
        flushing a buffer to the store it is about to lose is exactly what
        a `deactivate` callback is for, and a cascade that fired after the
        provider was already gone would make that impossible.

        Order: consumers deepest-first, then the provider. `unload` and
        `close` inherit it, UNDER EITHER DEPENDENCY POLICY, which is what
        makes apply's reverse-load-order teardown safe even when a
        document happens to list a consumer before its provider.
        """
        if seen.get(provider['ref']):
            return
        seen[provider['ref']] = True

        for ref in self._consumersof(provider['ref']):
            consumer = self._inst[ref]
            if 'live' != consumer['status']:
                continue
            self._cascade(consumer, seen)          # deepest-first
            try:
                self._run(consumer, 'deactivate', 'deactivate')
            except Exception:
                pass                                # section 12
            self._unwind(consumer)
            consumer['status'] = 'pending'
            consumer['unmet'] = self._unmetof(consumer)

    def _held(self, entry):
        """The hold check is A GUARD ON AD-HOC DEACTIVATION, NOT ON
        COORDINATED TEARDOWN. In a bulk operation that is removing the
        holders too - `close()`, or an `apply` plan whose own steps
        deactivate them - it is suspended for exactly those holders, and
        the teardown still runs consumers before providers.

        Otherwise `close()` under `hold` would raise on the first provider
        it reached whenever a document happened to list a consumer after
        it, which is the policy refusing to allow the one teardown it has
        no reason to object to.
        """
        if 'hold' != self._dependency:
            return
        if self._coordinated:
            return
        holders = self._consumersof(entry['ref'])
        if 0 == len(holders):
            return
        fail('plugin_dependency_held',
             'instance is required by live consumers: ' + entry['ref'],
             {'ref': entry['ref'], 'holders': holders})

    def _reconcile(self):
        """EAGER reconciliation: run to a fixed point rather than
        scheduling.

        Two directions, and both are the reason `pending` exists.
        Activation is a STANDING REQUEST, not a one-shot event: a pending
        instance whose requirement arrives activates without being asked
        again, and a LIVE instance whose requirement is lost goes back to
        pending - recursively, through its own consumers.
        """
        moved = True
        rounds = 0
        while moved:
            moved = False
            rounds += 1
            if 1000 < rounds:
                break

            # Losses first, so a cascade settles in one pass rather than
            # alternating with re-activations.
            for ref in sorted(self._inst):
                entry = self._inst[ref]
                if 'live' != entry['status']:
                    continue
                lost = [q for q in requirements(entry['options'])
                        if gatesactivation(q)
                        and 0 == len(self._providersof(q))]
                if 0 == len(lost):
                    continue
                # POLICY IS PER REQUIREMENT, not per instance (section
                # 11.3): only the definition that has the requirement
                # knows what it can cope with, and one instance may hold
                # both a `static` and a `dynamic` one. A `dynamic`
                # requirement whose provider is gone leaves the consumer
                # LIVE and notified; it is a statement about surviving a
                # swap, so it does not restart here.
                if not any(restartsonloss(q) for q in lost):
                    continue
                try:
                    self._run(entry, 'deactivate', 'deactivate')
                except Exception:
                    pass
                self._unwind(entry)
                entry['status'] = 'pending'
                entry['unmet'] = self._unmetof(entry)
                moved = True

            for ref in sorted(self._inst):
                entry = self._inst[ref]
                if 'pending' != entry['status']:
                    continue
                if 0 < len(self._unmetof(entry)):
                    continue
                try:
                    self._run(entry, 'activate', 'activate')
                    entry['status'] = 'live'
                    entry['unmet'] = []
                    moved = True
                except Exception:
                    self._unwind(entry)
                    entry['status'] = 'failed'
                    moved = True

    # --- ordering -----------------------------------------------------

    def order(self, point=None):
        bindings = [
            {'ref': r, 'pos': self._inst[r]['pos'],
             'order': self._inst[r]['order']}
            for r in self._inst if 'live' == self._inst[r]['status']
        ]
        spec = self._points.get(point) if point else None
        return resolve_order(bindings, spec.get('pin') if spec else None)

    # --- points -------------------------------------------------------

    def _bound(self, point):
        """Live bindings on a point, in resolved order. Recomputed on any
        change to the live set (section 7) rather than cached at startup -
        the bug a host discovers only when something deactivates in
        production."""
        out = []
        for ref in self.order(point):
            entry = self._inst[ref]
            # The band is the INSTANCE's ordering block (section 7),
            # stamped by the host. A plugin passing its own would be
            # ranking itself above the order its document declared.
            block = entry['order'] or {}
            band = block.get('band')
            band = band if isinstance(band, int) and not isinstance(band, bool) else 0
            for b in entry['bindings']:
                if b['point'] == point:
                    out.append(dict(b, band=band))
        return out

    def _pointspec(self, point, want):
        spec = self._points.get(point)
        if None is spec:
            fail('plugin_point_unknown', 'no such point: ' + point,
                 {'point': point})
        kind = spec.get('kind')
        if 'hook' == want:
            # A point with no declared kind is a hook, which is what makes
            # `{}` the minimal point declaration.
            if kind and 'hook' != kind:
                fail('plugin_point_kind', 'point is not a hook: ' + point,
                     {'point': point, 'kind': kind})
            return spec
        if kind != want:
            fail('plugin_point_kind',
                 'point is not a ' + want + ': ' + point,
                 {'point': point, 'kind': kind})
        return spec

    def emit(self, point, arg=None):
        spec = self._pointspec(point, 'hook')
        return fanout(self._bound(point), spec.get('mode') or 'emit', arg)

    def call(self, point, *args):
        spec = self._pointspec(point, 'chain')
        base = spec.get('base') or (lambda *a: a[0] if 0 < len(a) else None)
        return compose(self._bound(point), base)(*args)

    def provider(self, point, *args):
        spec = self._pointspec(point, 'provider')
        pick = pickone(self._bound(point), spec)
        if not pick['winner']:
            return spec.get('default')
        return pick['winner']['fn'](*args)

    def shadowed(self, point):
        """The losers are VISIBLE rather than silently ignored (section
        6.3)."""
        spec = self._points.get(point)
        if None is spec:
            return []
        return pickone(self._bound(point), spec)['shadowed']

    def exports(self, spec):
        allof = []
        for ref in sorted(self._inst):
            entry = self._inst[ref]
            # Exports of a `loaded` (not live) instance are VISIBLE
            # (section 11).
            if entry['status'] in ('declared', 'failed'):
                continue
            for key in sorted(entry['exports']):
                allof.append({'ref': ref, 'key': key,
                              'value': entry['exports'][key]})
        return resolve_export(spec, allof)

    def capability(self, name):
        """The live providers of a capability, best-first (section
        11.1)."""
        cands = []
        for ref in sorted(self._inst):
            entry = self._inst[ref]
            if 'live' != entry['status']:
                continue
            for prov in entry['provides']:
                if prov.get('name') == name:
                    cands.append({'ref': ref, 'pos': entry['pos'],
                                  'provides': prov})
        return [c['ref'] for c in resolve_capability({'name': name}, cands)]

    # --- documents ----------------------------------------------------

    def apply(self, doc, profile=None):
        self._guard()
        profile = profile or self._opts.get('profile')
        norm = normalize_config({
            'doc': doc, 'profile': profile,
            'keys': self._opts.get('keys'), 'reserved': self._reserved,
        })

        for ref in norm['order']:
            ent = norm['instance'][ref]
            defaults = self._opts.get('defaults') or {}
            options = resolve_options({
                'ref': ref, 'doc': doc, 'profile': profile,
                'shape': self._shapeof(ref),
                'hostdefaults': defaults.get(parse_ref(ref)['name']),
            })

            existing = self._inst.get(ref)
            wantlive = ent['active'] and 'eager' == ent['start']

            # Toggling back to lazy or inactive returns it to `declared`,
            # BY UNLOADING IT (section 9.6). There is no loaded->declared
            # transition and there should not be one: going back to
            # `declared` means "as if never loaded", and an instance that
            # has run `define` has state and bindings that only `close`
            # can properly undo.
            if existing and not wantlive and 'declared' != existing['status']:
                self.unload(ref)

            self.declare(ref, {'options': options, 'order': ent.get('order'),
                               'pos': ent['pos']})
            # REFILL rather than REBIND. A definition's callbacks close
            # over the options map they were handed at `define`; replacing
            # the reference here would leave every binding reading the
            # values the first apply gave it, and a re-applied document
            # would silently do nothing. Clearing and refilling the same
            # map is portable to every language, unlike a getter or an
            # interception hook - which the section 18 portability budget
            # forbids anyway.
            refill(self._inst[ref]['options'], options)
            self._inst[ref]['order'] = ent.get('order')
            self._inst[ref]['pos'] = ent['pos']

            if wantlive:
                self.ready(ref)

    def _shapeof(self, ref):
        definition = self.catalog.get(parse_ref(ref)['name'])
        return definition.get('shape') if definition else None

    def options(self, ref, patch):
        self._guard()
        entry = self._need(ref)
        previous = dict(entry['options'])
        refill(entry['options'], resolve_options({
            'ref': entry['ref'], 'shape': self._shapeof(entry['ref']),
            'doc': {}, 'patch': dict(previous, **(patch or {})),
        }))
        if 'live' == entry['status']:
            reconfigure = entry['def'].get('reconfigure')
            if callable(reconfigure):
                self._intransition = True
                try:
                    reconfigure(Inst(self, entry), entry['options'], previous)
                finally:
                    self._intransition = False
            else:
                # Always correct and sometimes expensive; `reconfigure`
                # exists to make the common case cheap (section 9.4).
                self.deactivate(entry['ref'])
                self.activate(entry['ref'])

    def close(self):
        # A bulk teardown removing the holders too, so `hold` is suspended
        # for exactly those holders (section 11.3) - while the
        # consumers-first cascade still runs, which is the half that
        # matters.
        self._coordinated = True
        try:
            for ref in reversed(sorted(self._inst)):
                self.unload(ref)
        finally:
            self._coordinated = False

    def positionof(self, ref, point):
        """The same record section 6.6 gives a plugin about itself,
        reachable from outside for the corpus. A plugin asks via
        `inst.position(point)`."""
        entry = self._inst.get(canon_ref(ref))
        if not entry:
            fail('plugin_not_loaded', 'no such instance: ' + ref,
                 {'ref': ref})
        ranked = self.order(point)
        index = ranked.index(entry['ref']) if entry['ref'] in ranked else -1
        return {
            'index': index, 'count': len(ranked),
            # Section 6.2 composes b1(b2(b3(base))) with the FIRST binding
            # OUTERMOST, so these are not index 0 and index count-1 the
            # other way round. Getting this backwards is the exact error
            # the positional pin vocabulary exists to prevent.
            'outermost': 0 == index,
            'innermost': index == len(ranked) - 1,
        }

    def define(self, definition):
        self.catalog.add(definition)


def refill(target, source):
    """Empty the target and refill it, so callers holding the reference
    see the new values."""
    target.clear()
    target.update(source or {})
