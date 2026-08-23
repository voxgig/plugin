"""Dependency cardinality, policy, and the restart graph (section 11.3).

TWO AXES, BOTH DECLARED BY THE DEFINITION THAT HAS THE REQUIREMENT,
because only it knows what it can cope with:

               | static (default)          | dynamic
  -------------|---------------------------|--------------------------
  mandatory    | unmet -> pending;         | unmet -> pending;
  (default)    | lost  -> pending,         | lost  -> STAYS LIVE,
               |          recursively      |          notified
  -------------|---------------------------|--------------------------
  optional:true| never gates activation;   | never gates activation;
               | a change deactivates and  | a change is a
               | reactivates               | notification, nothing else

`dynamic` means the plugin has said, IN WRITING, that it can survive its
provider being swapped underneath it. It is not the default because most
plugins cannot, and the cost of wrongly assuming they can is a live
instance holding a dead reference.

The rebinding-preference axis is deliberately omitted. OSGi has reluctant
vs greedy and it is a knob every author must understand to read anyone
else's component; we take always-reluctant. Three axes were more than the
model can carry across twenty ports.
"""

from .types import fail


def normrequire(raw):
    """A bare string is shorthand for `{name}`."""
    if isinstance(raw, str):
        return {'name': raw}
    return dict(raw or {})


def requirements(options):
    """The requirements a definition declared, normalized.

    BOTH AXES ARE READ AT TWO LEVELS, AND THE PER-REQUIREMENT ONE WINS.

    The instance-level `policy` and `optional` list are how a DOCUMENT
    states the axis without editing the definition, and they apply to
    every requirement. The per-requirement form is the one section 11.1's
    object syntax exists for, and it is strictly more expressive: an
    instance that is `static` on its store and `dynamic` on its metrics
    cannot be written at all at the instance level, and that is the
    ordinary case rather than an exotic one.

    `optional` unions rather than overriding - both spellings are
    statements that this requirement need not gate activation, and there
    is no reading under which one of them means "actually, mandatory".
    """
    options = options or {}
    raw = options.get('requires') or []
    marked = options.get('optional') or []
    fallback = options.get('policy')

    out = []
    for item in raw:
        req = normrequire(item)
        if req.get('optional') or req.get('name') in marked:
            req['optional'] = True
        if None is req.get('policy') and None is not fallback:
            req['policy'] = fallback
        out.append(req)
    return out


def restartsonloss(req):
    """Does losing this requirement's SELECTED provider restart the
    consumer? The mandatory ones under `static`, and the `static` optional
    ones - both make a capability change deactivate and reactivate.
    `dynamic` never restarts: mandatory-dynamic stays live and is
    notified, optional-dynamic is a notification and nothing else."""
    return 'dynamic' != (req.get('policy') or 'static')


def gatesactivation(req):
    """Does an unmet requirement keep the consumer out of `live`?

    Cardinality alone decides this, NOT policy. `dynamic` is a statement
    about surviving a SWAP, not about starting without the thing at all -
    a mandatory-dynamic consumer still waits in `pending` for its first
    provider. Conflating the two would let a plugin that declared it can
    cope with replacement activate with nothing to call.
    """
    return True is not req.get('optional')


def restartcausing(req):
    """Edges that can cause a restart, which is exactly the set a cycle
    must be detected over (section 11.3).

    Those are the mandatory requirements AND THE `static` OPTIONAL ONES,
    because both make a capability change deactivate and reactivate the
    consumer - and a cycle of restarts does not settle: A comes up, B
    restarts, which changes B's capability, which restarts A,
    indefinitely.

    ONLY `dynamic` OPTIONAL EDGES ARE EXCLUDED, and they are the ones the
    exclusion was for: two plugins that optionally and dynamically consume
    each other's capabilities both activate happily, neither gates on the
    other, and each is merely notified when the other appears. Nothing
    restarts, so nothing oscillates.

    An earlier draft of section 11.3 excluded EVERY optional edge and
    thereby admitted the non-terminating case it was trying to permit.
    """
    return gatesactivation(req) or restartsonloss(req)


def dependencycycle(nodes):
    """A cycle through restart-causing requirements is
    `plugin_dependency_cycle`, detected AT LOAD - before anything runs,
    because the failure it describes is a non-terminating reconcile and
    the only safe time to report that is before it starts.

    The graph is over capabilities, not refs: an edge runs from a consumer
    to EVERY node that provides what it needs, because any of them could
    be the one selected and a cycle through any is a cycle. A node also
    satisfies its own name as a ref (section 11.1), which is why the ref
    is a provider of itself here.
    """
    provider = {}
    for node in nodes:
        for cap in list(node['provides']) + [node['ref']]:
            provider.setdefault(cap, []).append(node['ref'])

    edges = {}
    for node in nodes:
        out = []
        for req in node['requires']:
            if not restartcausing(req):
                continue
            for p in provider.get(req['name'], []):
                if p != node['ref'] and p not in out:
                    out.append(p)
        edges[node['ref']] = sorted(out)

    # Iterative DFS with an explicit stack: twenty ports, and several of
    # them have no recursion budget worth relying on.
    WHITE, GREY, BLACK = 0, 1, 2
    colour = {node['ref']: WHITE for node in nodes}

    for start in sorted(edges):
        if WHITE != colour[start]:
            continue
        path = [start]
        stack = [[start, 0]]
        colour[start] = GREY

        while 0 < len(stack):
            top = stack[-1]
            if top[1] >= len(edges[top[0]]):
                colour[top[0]] = BLACK
                stack.pop()
                path.pop()
                continue
            nxt = edges[top[0]][top[1]]
            top[1] += 1
            if GREY == colour[nxt]:
                # Report the cycle itself, not the walk that found it.
                return path[path.index(nxt):] + [nxt]
            if BLACK == colour[nxt]:
                continue
            colour[nxt] = GREY
            path.append(nxt)
            stack.append([nxt, 0])
    return None


def checkcycle(nodes):
    """Raise on a cycle, naming it. Separate from the detector so the
    detector stays pure and corpus-testable."""
    cycle = dependencycycle(nodes)
    if None is not cycle:
        fail('plugin_dependency_cycle',
             'requirements cycle: ' + ' -> '.join(cycle), {'cycle': cycle})
