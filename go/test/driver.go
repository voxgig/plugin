/* The driver (DOCS.md §4).
 *
 * Every port implements this same small thing and nothing else is
 * port-specific: the probe catalog, the command interpreter, and the
 * canonical observable.
 *
 * THE ONE GO-SHAPED DIFFERENCE is that a probe cannot throw. §12's
 * errors are RETURNED here, from the callback and from every host verb,
 * and the interpreter propagates instead of unwinding. `catch: true`
 * still means "record the raise and let the run continue", which is the
 * only way to observe a `failed` instance. */

package plugintest

import (
	"errors"
	"fmt"

	plugin "github.com/voxgig/plugin/go/plugin"
)

// Probes are §4.3's six probes. Their behaviour is as much the contract
// as the runner is — this is where twenty implementations of `noisy` are
// made to fail at the same callback in the same way.
func Probes() []plugin.Definition {
	record := func(name string) plugin.Definition {
		return plugin.Definition{
			Name: name,
			Define: func(i *plugin.Inst) error {
				i.State()["count"] = countof(i)
				return nil
			},
			Activate: func(i *plugin.Inst) error {
				_, err := i.Acquire()
				return err
			},
		}
	}

	probe := plugin.Definition{
		Name: "probe",
		Define: func(i *plugin.Inst) error {
			i.State()["count"] = countof(i)
			band := intopt(i, "band")
			// One hook binding (`p`) and one chain wrap (`c`) — the
			// workhorse shape DOCS.md §4.3 specifies.
			if err := i.Bind("p", func(args ...any) any {
				i.State()["count"] = countof(i) + 1
				return nil
			}, band); nil != err {
				return err
			}
			// Wrap AFTER next, so the result spells the nesting left to
			// right: outermost first. Wrapping the ARGUMENT instead
			// would spell it backwards and make every chain expectation
			// read wrong.
			if err := i.Bind("c", func(args ...any) any {
				next, _ := args[0].(plugin.BindFn)
				wrap := ":"
				if s, ok := i.Options()["wrap"].(string); ok {
					wrap = s
				}
				return wrap + tostr(next(args[1:]...))
			}, band); nil != err {
				return err
			}
			i.Export("client", i.Ref())
			// The instance api itself, so the driver's `stray` command
			// can call Release from OUTSIDE a lifecycle callback.
			i.Export("inst", i)
			return declareprovides(i)
		},
		Activate: func(i *plugin.Inst) error {
			if _, err := i.Acquire(); nil != err {
				return err
			}
			// §6.5: an instance that is itself a host. The outer owns
			// the inner's lifetime — registered in the scope, so it
			// closes on deactivate in the same reverse unwind as every
			// other resource.
			nest, ok := i.Options()["nest"].([]any)
			if !ok {
				return nil
			}
			inner, err := i.Nest(plugin.HostOptions{Points: withpoints(nil)})
			if nil != err {
				return err
			}
			for _, d := range Probes() {
				if err := inner.Catalog().Add(d); nil != err {
					return err
				}
			}
			for _, r := range nest {
				if _, err := inner.Ready(tostr(r)); nil != err {
					return err
				}
			}
			return nil
		},
	}

	noisy := plugin.Definition{
		Name: "noisy",
		Define: func(i *plugin.Inst) error {
			i.State()["count"] = countof(i)
			return boom(i, "define")
		},
		Activate: func(i *plugin.Inst) error {
			// Acquire BEFORE the raise, so a failing activate has
			// something to leak if the scope does not unwind — which is
			// the whole point of the entry that asserts open === 0
			// afterwards.
			if _, err := i.Acquire(); nil != err {
				return err
			}
			if err := reenter(i, "activate"); nil != err {
				return err
			}
			return boom(i, "activate")
		},
		Deactivate: func(i *plugin.Inst) error { return boom(i, "deactivate") },
		Close:      func(i *plugin.Inst) error { return boom(i, "close") },
	}

	greedy := plugin.Definition{
		Name: "greedy",
		Define: func(i *plugin.Inst) error {
			i.State()["count"] = 0
			// §8.1 puts resource capture in `activate`. `early` NAMES the
			// call that reaches for it in `define`, because Acquire and
			// Release carry the guard separately.
			if "acquire" == tostr(i.Options()["early"]) {
				if _, err := i.Acquire(); nil != err {
					return err
				}
			}
			if "release" == tostr(i.Options()["early"]) {
				if err := i.Release(func() {}); nil != err {
					return err
				}
			}
			return nil
		},
		Activate: func(i *plugin.Inst) error {
			n := intopt(i, "acquire")
			rel := intopt(i, "release")
			handles := []func(){}
			for k := 0; k < n; k++ {
				h, err := i.Acquire()
				if nil != err {
					return err
				}
				handles = append(handles, h)
			}
			// Release some explicitly; the DIFFERENCE is what the
			// instance scope must unwind by itself (§8.3), and that
			// difference is the whole test.
			for k := 0; k < rel && k < len(handles); k++ {
				handles[k]()
			}

			// `mark` registers N FOREIGN releases — §8.3's `release`,
			// the half `acquire` cannot exercise — each recording its
			// own index as it runs.
			//
			// THE RECORDED LIST IS THE ONLY THING THAT DISTINGUISHES A
			// REVERSE UNWIND FROM A FORWARD ONE. An acquired handle is
			// an idempotent counter decrement, so running the handles in
			// either direction leaves the same `open`, and a port
			// unwinding forwards passed every other entry in this
			// section.
			// `bind` is `early`'s counterpart for §8.1's OTHER half.
			// Binding declaration belongs in `define`; this names the
			// callback that tries it from somewhere else.
			if "activate" == tostr(i.Options()["bind"]) {
				if err := i.Bind("p", func(args ...any) any { return nil }, 0); nil != err {
					return err
				}
			}

			mark := intopt(i, "mark")
			unwound := []any{}
			i.State()["unwound"] = unwound
			markfail, _ := i.Options()["markfail"].(bool)
			for k := 0; k < mark; k++ {
				k := k
				if err := i.Release(func() {
					// `markfail` makes the release FAIL. A Go release is
					// `func()` and cannot return an error, so it signals
					// by panicking — which the host recovers, exactly as
					// it must for a real `defer f.Close()` wrapper that
					// has nowhere to put its error.
					if markfail {
						panic("release failed at " + itoa(k))
					}
					l, _ := i.State()["unwound"].([]any)
					i.State()["unwound"] = append(l, k)
				}); nil != err {
					return err
				}
			}
			return nil
		},
		// `deactivate` completes the pair: the guard is on the PHASE,
		// not on "not define", and an entry exercising only one leaves
		// the other's mutation alive.
		Deactivate: func(i *plugin.Inst) error {
			if "deactivate" == tostr(i.Options()["bind"]) {
				return i.Bind("p", func(args ...any) any { return nil }, 0)
			}
			return nil
		},
	}

	dep := plugin.Definition{
		Name: "dep",
		Define: func(i *plugin.Inst) error {
			i.State()["count"] = 0
			if err := declareprovides(i); nil != err {
				return err
			}
			if ex, ok := i.Options()["exports"].(map[string]any); ok {
				for _, k := range sortedkeys(ex) {
					i.Export(k, ex[k])
				}
			}
			return nil
		},
		Activate: func(i *plugin.Inst) error { _, err := i.Acquire(); return err },
	}

	provider := plugin.Definition{
		Name: "provider",
		Define: func(i *plugin.Inst) error {
			i.State()["count"] = 0
			point := "v"
			if s, ok := i.Options()["point"].(string); ok {
				point = s
			}
			if err := i.Bind(point, func(args ...any) any {
				if v, has := i.Options()["value"]; has {
					return v
				}
				return i.Ref()
			}, intopt(i, "band")); nil != err {
				return err
			}
			return declareprovides(i)
		},
		Activate: func(i *plugin.Inst) error { _, err := i.Acquire(); return err },
	}

	return []plugin.Definition{
		probe, noisy, greedy, dep, provider,
		record("slow"), record("other"), record("adapter"), record("late"),
	}
}

func declareprovides(i *plugin.Inst) error {
	raw, ok := i.Options()["provides"].([]any)
	if !ok {
		return nil
	}
	for _, p := range raw {
		var prov plugin.Provided
		if err := decode(p, &prov); nil != err {
			return err
		}
		i.Provides(prov)
	}
	return nil
}

func boom(i *plugin.Inst, cb string) error {
	if s, ok := i.Options()["fail"].(string); ok && cb == s {
		// `bare` returns an error with NO CODE — the ordinary library
		// error §12's `plugin_<phase>_failed` codes exist to wrap.
		if bare, _ := i.Options()["bare"].(bool); bare {
			return errors.New("probe failed at " + cb)
		}
		code := "plugin_" + cb + "_failed"
		if c, ok := i.Options()["code"].(string); ok {
			code = c
		}
		return plugin.Fail(code, "probe failed at "+cb, nil)
	}
	return nil
}

func reenter(i *plugin.Inst, cb string) error {
	if s, ok := i.Options()["reenter"].(string); ok && cb == s {
		// A transition from inside a lifecycle callback (§5.2).
		_, err := i.Host().Activate(i.Ref())
		return err
	}
	return nil
}

func countof(i *plugin.Inst) int {
	switch n := i.State()["count"].(type) {
	case int:
		return n
	case float64:
		return int(n)
	}
	return 0
}

func intopt(i *plugin.Inst, key string) int {
	switch n := i.Options()[key].(type) {
	case int:
		return n
	case float64:
		return int(n)
	}
	return 0
}

func tostr(v any) string {
	if s, ok := v.(string); ok {
		return s
	}
	if nil == v {
		return ""
	}
	return fmt.Sprint(v)
}

/* BASEPOINTS are the points every driver host declares. DOCS.md §4.3
 * defines `probe` as binding one hook point (`p`) and wrapping one chain
 * point (`c`), so a host without them cannot load the probe at all —
 * they are part of the contract's baseline rather than a fixture
 * convenience. `v` is the provider point the `provider` probe defaults
 * to. */
func basepoints() map[string]plugin.Spec {
	return map[string]plugin.Spec{
		"p": {Kind: plugin.KindHook},
		"c": {Kind: plugin.KindChain, Base: func(args ...any) any {
			if 0 == len(args) {
				return nil
			}
			return args[0]
		}},
		"v": {Kind: plugin.KindProvider},
	}
}

func withpoints(extra map[string]plugin.Spec) map[string]plugin.Spec {
	out := basepoints()
	for k, v := range extra {
		// A `host` command REPLACES a base point rather than merging
		// into it, so an entry can redeclare `c` with its own base or
		// `v` as exclusive without inheriting the default's shape.
		out[k] = v
	}
	return out
}

func withprobes() *plugin.Catalog {
	c, err := plugin.MakeCatalog(Probes()...)
	if nil != err {
		panic(err)
	}
	return c
}

// Drive runs a command list and returns §4.5's observable. Stops at the
// first raise; the entry's `err` matches its code.
func Drive(cmds []any) (any, error) {
	host := plugin.MakeHost(plugin.HostOptions{
		Catalog: withprobes(), Points: withpoints(nil)})

	// §4.5: `result` is the value of THE LAST COMMAND THAT PRODUCES ONE.
	// Storing it and continuing — rather than returning at the first
	// producing command — is what lets an entry emit and then inspect,
	// which most of `point` needs.
	var last any

	for _, raw := range cmds {
		c, _ := raw.(map[string]any)
		newhost, value, err := docmd(host, c)
		if nil != newhost {
			host = newhost
		}
		if nil != value {
			last = value.result
		}
		if nil != err {
			// §4.1: `catch` records the raise and lets the run continue,
			// which is the only way to observe a `failed` instance —
			// §5.2's whole claim is that it stays registered and
			// inspectable.
			if catch, _ := c["catch"].(bool); !catch {
				return nil, err
			}
		}
	}
	return host.Observable(last), nil
}

// produced wraps a command's result so "produced nothing" and "produced
// nil" stay distinguishable — `export` of a missing key legitimately
// produces null, and it must overwrite a previous result.
type produced struct{ result any }

func docmd(host *plugin.Host, c map[string]any) (*plugin.Host, *produced, error) {
	ref := tostr(c["ref"])
	point := tostr(c["point"])
	spec := declspec(c)

	switch tostr(c["do"]) {

	case "host":
		var reserved []string
		for _, r := range listof(c["reserved"]) {
			reserved = append(reserved, tostr(r))
		}
		var keys plugin.Keys
		_ = decode(c["keys"], &keys)
		var points map[string]plugin.Spec
		_ = decode(c["points"], &points)
		defaults, _ := c["defaults"].(map[string]any)
		return plugin.MakeHost(plugin.HostOptions{
			Catalog:  withprobes(),
			Reserved: reserved, Keys: keys, Defaults: defaults,
			Profile: tostr(c["profile"]), Points: withpoints(points),
			// §11.3's strict reading. Absent means `restart`, which is
			// the default precisely because a station that cannot swap a
			// provider without a restart has lost the argument for
			// having a plugin system.
			Dependency: tostr(c["dependency"]),
		}), nil, nil

	case "define":
		// The catalog is pre-seeded with the probe set; `define` names
		// which entry backs this definition.
		return nil, nil, nil

	case "load":
		_, err := host.Load(ref, spec)
		return nil, nil, err

	case "ready":
		// declare FIRST, so the ordering block and definition reach the
		// instance — `ready` walks the staircase, it does not carry
		// configuration of its own.
		if _, err := host.Declare(ref, spec); nil != err {
			return nil, nil, err
		}
		_, err := host.Ready(ref)
		return nil, nil, err

	case "activate":
		_, err := host.Activate(ref)
		return nil, nil, err

	case "deactivate":
		_, err := host.Deactivate(ref)
		return nil, nil, err

	case "unload":
		return nil, nil, host.Unload(ref)

	case "apply":
		return nil, nil, host.Apply(c["doc"], tostr(c["profile"]))

	case "options":
		patch, _ := c["patch"].(map[string]any)
		return nil, nil, host.SetOptions(ref, patch)

	case "close":
		return nil, nil, host.Close()

	case "list":
		return nil, &produced{host.List()}, nil

	case "emit":
		v, err := host.Emit(point, c["arg"])
		return nil, &produced{v}, err

	case "chain":
		v, err := host.Call(point, c["arg"])
		return nil, &produced{v}, err

	case "provider":
		v, err := host.Provide(point, c["arg"])
		return nil, &produced{v}, err

	case "shadowed":
		v, err := host.Shadowed(point)
		return nil, &produced{v}, err

	case "export":
		v, err := host.Exports(tostr(c["key"]))
		return nil, &produced{v}, err

	case "capability":
		return nil, &produced{host.Capability(tostr(c["name"]))}, nil

	case "trace":
		return nil, &produced{host.Trace()}, nil

	case "hostdeclare":
		// §9.1's host-owned path: the embedding host installing the
		// instance whose name it reserved.
		e, err := host.HostDeclare(ref, spec)
		if nil != err {
			return nil, nil, err
		}
		return nil, &produced{e.Ref}, nil

	case "declare":
		e, err := host.Declare(ref, spec)
		if nil != err {
			return nil, nil, err
		}
		return nil, &produced{e.Ref}, nil

	case "seq":
		// A malformed ref is a NAME error, not an absent instance —
		// `Instance` propagates it and the driver must not swallow it,
		// or `declare/lookup#malformed` reads as a plain miss.
		e, err := host.Instance(ref)
		if nil != err {
			return nil, nil, err
		}
		if nil != e {
			return nil, &produced{e.Seq}, nil
		}
		return nil, &produced{nil}, nil

	case "pos":
		e, err := host.Instance(ref)
		if nil != err {
			return nil, nil, err
		}
		if nil != e {
			return nil, &produced{e.Pos}, nil
		}
		return nil, &produced{nil}, nil

	case "inner":
		e, err := host.Instance(ref)
		if nil != err {
			return nil, nil, err
		}
		if nil != e && nil != e.Inner {
			return nil, &produced{e.Inner.List()}, nil
		}
		return nil, &produced{nil}, nil

	case "order":
		v, err := host.Order(point)
		return nil, &produced{v}, err

	case "call":
		return docall(host, c, ref, point)
	}

	return nil, nil, fmt.Errorf("unknown driver command: %s", tostr(c["do"]))
}

func docall(host *plugin.Host, c map[string]any, ref string, point string) (*plugin.Host, *produced, error) {
	e, err := host.Instance(ref)
	if nil != err {
		return nil, nil, err
	}
	if nil == e {
		return nil, nil, plugin.Fail("plugin_not_loaded", "no such instance: "+ref, nil)
	}
	switch tostr(c["method"]) {
	case "bump":
		n := 0
		switch v := e.State["count"].(type) {
		case int:
			n = v
		case float64:
			n = int(v)
		}
		e.State["count"] = n + 1
		return nil, nil, nil
	case "count":
		switch v := e.State["count"].(type) {
		case int:
			return nil, &produced{v}, nil
		case float64:
			return nil, &produced{int(v)}, nil
		}
		return nil, &produced{0}, nil
	case "unwound":
		if l, ok := e.State["unwound"].([]any); ok {
			return nil, &produced{l}, nil
		}
		return nil, &produced{[]any{}}, nil
	case "position":
		// Reached through the instance api, which is where §6.6 puts it
		// — a plugin asks about itself.
		p, err := host.PositionOf(ref, point)
		return nil, &produced{p}, err
	case "stray":
		// A release from OUTSIDE a lifecycle callback. THIS BRANCH USED
		// TO DO NOTHING, and its corpus row stayed green whatever
		// Release did with its guard.
		raw, err := host.Exports(ref + "/inst")
		if nil != err {
			return nil, nil, err
		}
		api, ok := raw.(*plugin.Inst)
		if !ok {
			return nil, nil, fmt.Errorf("no instance api exported by %s", ref)
		}
		return nil, nil, api.Release(func() {})
	}
	return nil, nil, nil
}

func declspec(c map[string]any) plugin.DeclareSpec {
	spec := plugin.DeclareSpec{
		Definition: tostr(c["definition"]),
		Tag:        tostr(c["tag"]),
	}
	if o, ok := c["options"].(map[string]any); ok {
		spec.Options = o
	}
	if _, has := c["order"]; has {
		var ob plugin.OrderBlock
		if nil == decode(c["order"], &ob) {
			spec.Order = &ob
		}
	}
	return spec
}

func listof(v any) []any {
	l, _ := v.([]any)
	return l
}
