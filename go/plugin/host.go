/* The host: the lifecycle state machine (§5), extension points (§6), and
 * resource capture (§8).
 *
 * TWO RULES SHAPE EVERY METHOD BELOW.
 *
 * Transitions are SEQUENTIAL (§5.2). One at a time, in call order, never
 * interleaved; a transition triggered from inside a lifecycle callback
 * is `plugin_reentrant`. A hard rule, because it is the only way the
 * semantics can be identical in Go, in Ruby and in single-threaded
 * JavaScript.
 *
 * Reconciliation is EAGER (§18's portability budget). A transition
 * settles by running the state machine to a fixed point, not by
 * suspending on a promise. Every port must be able to do the same, and
 * fourteen of them will not have JavaScript's event loop. */

package plugin

import (
	"fmt"
	"sort"
)

type PointSpec = Spec

type HostOptions struct {
	Catalog  *Catalog
	Reserved []string
	Keys     Keys
	Defaults map[string]any
	Profile  string
	Points   map[string]Spec
	// Dependency is §11.3. `restart` (the default) treats provider
	// replacement as an ordinary runtime operation: deactivate the old
	// store, activate the new one, and everything that depended on it
	// rides through, having released the old one's resources in between.
	//
	// `hold` is the strict reading — deactivating a required instance is
	// `plugin_dependency_held`, naming the holders. NOT the default,
	// because a station that cannot swap a provider without a restart
	// has lost the argument for having a plugin system.
	Dependency string
}

// Live is one instance's record. The exported half is what
// introspection reads; the rest is the host's.
type Live struct {
	Ref     string
	Status  Status
	Pos     int
	Seq     int
	Options map[string]any
	State   map[string]any
	// Inner is set when this instance is itself a host (§6.5).
	Inner *Host

	def   Definition
	order *OrderBlock
	// unmet holds requirements this instance declared but has not been
	// given.
	unmet []string
	// scope holds the resources the instance scope holds, newest last —
	// unwound in REVERSE, because that is the only order in which
	// teardown mirrors setup (§8.3).
	scope []func()
	// bindings are declared in `define`, inserted only when activation
	// SUCCEEDS (§8.1). Holding them until then is what makes a failed
	// activate leave nothing behind.
	bindings []Bound
	// exports are declared in `define`, and VISIBLE while merely
	// `loaded` (§11): they are data, and hiding them would make the
	// loaded state useless for introspection.
	exports  map[string]any
	provides []Provided
}

type Event struct {
	Ref    string `json:"ref"`
	Event  string `json:"event"`
	Seq    int    `json:"seq"`
	Status Status `json:"status"`
}

type Observable struct {
	Status map[string]Status `json:"status"`
	Open   int               `json:"open"`
	Log    []string          `json:"log"`
	Result any               `json:"result"`
}

type Host struct {
	opts       HostOptions
	catalog    *Catalog
	reserved   []string
	points     map[string]Spec
	dependency string

	// coordinated is set for the duration of a bulk teardown, so `held`
	// knows this is a coordinated operation rather than an ad-hoc
	// deactivation.
	coordinated bool

	inst map[string]*Live
	log  []string
	// events is §14: the lifecycle event record. `seq` distinguishes ONE
	// INCARNATION of stripe$test from the next, which is the whole
	// reason it is not `pos` (§4 rule 4).
	events       []Event
	seqn         int
	open         int
	intransition bool
	// phase is WHICH callback is running, not merely that one is. §8.1
	// puts resource capture in `activate` and §8.3 says `Release`
	// outside `activate` is `plugin_release_scope` — and `intransition`
	// alone cannot tell `activate` from `define`, so it admitted an
	// Acquire in `define` whose scope `Unload` would never unwind.
	phase string
}

func MakeHost(options HostOptions) *Host {
	h := &Host{
		opts:       options,
		catalog:    options.Catalog,
		reserved:   options.Reserved,
		points:     options.Points,
		dependency: or(options.Dependency, "restart"),
		inst:       map[string]*Live{},
		log:        []string{},
		events:     []Event{},
	}
	if nil == h.catalog {
		h.catalog, _ = MakeCatalog()
	}
	if nil == h.points {
		h.points = map[string]Spec{}
	}
	return h
}

func (h *Host) Catalog() *Catalog { return h.catalog }

// --- observation -----------------------------------------------------

// List is introspection, and introspection NEVER advances the state
// (§5.2). A status page must not be a way to accidentally import twenty
// packages.
func (h *Host) List() map[string]Status {
	out := map[string]Status{}
	for _, r := range sortedkeys(h.inst) {
		out[r] = h.inst[r].Status
	}
	return out
}

func (h *Host) Instance(ref string) *Live { return h.inst[canon(ref)] }

func (h *Host) Trace() []Event { return append([]Event{}, h.events...) }

func (h *Host) Observable(result any) Observable {
	return Observable{
		Status: h.List(),
		Open:   h.open,
		Log:    append([]string{}, h.log...),
		Result: result,
	}
}

// --- the state machine -----------------------------------------------

func (h *Host) guard() error {
	if h.intransition {
		return Fail("plugin_reentrant",
			"transition attempted from inside a lifecycle callback", nil)
	}
	return nil
}

func (h *Host) need(ref string) (*Live, error) {
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	e := h.inst[r]
	if nil == e {
		return nil, Fail("plugin_not_loaded", "no such instance: "+r,
			map[string]any{"ref": r})
	}
	return e, nil
}

func (h *Host) checkreserved(ref string) error {
	return checkreservedref(ref, h.reserved)
}

func (h *Host) run(e *Live, fn func(*Inst) error, at string) error {
	h.log = append(h.log, e.Ref+":"+at)
	h.events = append(h.events, Event{Ref: e.Ref, Event: at, Seq: e.Seq, Status: e.Status})
	if nil == fn {
		return nil
	}
	h.intransition = true
	h.phase = at
	defer func() { h.intransition = false; h.phase = "" }()
	err := fn(h.api(e))
	if nil == err {
		return nil
	}
	// §12: `plugin_define_failed` and its three siblings are "a callback
	// raised; wraps the cause". AN ERROR THAT ALREADY CARRIES A CODE
	// KEEPS IT — the code is the error's identity, and a plugin
	// returning `store_unreachable` must not have it rewritten. Only a
	// code-less error is wrapped, which is the ordinary case for a
	// callback that let a library error through.
	if "" != CodeOf(err) {
		return err
	}
	return Fail("plugin_"+at+"_failed",
		e.Ref+" raised in "+at+": "+err.Error(),
		map[string]any{"ref": e.Ref, "cause": err.Error()})
}

// Inst is what a definition's callbacks see. Deliberately not the
// internal record: a plugin that could reach `Status` could also write
// it.
type Inst struct {
	h *Host
	e *Live
}

func (h *Host) api(e *Live) *Inst { return &Inst{h: h, e: e} }

func (i *Inst) Ref() string             { return i.e.Ref }
func (i *Inst) Name() string            { return refname(i.e.Ref) }
func (i *Inst) Tag() string             { r, _ := ParseRef(i.e.Ref); return r.Tag }
func (i *Inst) Options() map[string]any { return i.e.Options }
func (i *Inst) State() map[string]any   { return i.e.State }
func (i *Inst) Host() *Host             { return i.h }

// Release registers a foreign resource the host did not hand out (§8.3);
// host calls are recorded automatically.
func (i *Inst) Release(fn func()) error {
	// §8.3: "`inst.release` outside `activate` is
	// `plugin_release_scope`". `intransition` is true in `define` too,
	// and a scope entry registered there is never unwound.
	if "activate" != i.h.phase {
		return Fail("plugin_release_scope", "release called outside activate", nil)
	}
	// SYMMETRIC WITH Acquire, and it has to be: `open` counts the
	// resources CURRENTLY HELD, so an entry that is registered and then
	// unwound must leave the count where it found it.
	done := false
	h := i.h
	i.e.scope = append(i.e.scope, func() {
		if !done {
			done = true
			h.open -= 1
			fn()
		}
	})
	h.open += 1
	return nil
}

// Acquire is the synthetic counter the driver owns, so "what is open" is
// data rather than an assertion each port words differently.
//
// Returns its own release, so a plugin can hand one back early. The
// scope still holds the entry and unwinding it twice is a no-op —
// releasing early must not make teardown wrong.
func (i *Inst) Acquire() (func(), error) {
	// §8.1: resources are "acquired during `activate` — the scope's
	// actual job". Same reason as `Release` above.
	if "activate" != i.h.phase {
		return nil, Fail("plugin_release_scope", "acquire called outside activate", nil)
	}
	done := false
	h := i.h
	rel := func() {
		if !done {
			done = true
			h.open -= 1
		}
	}
	i.e.scope = append(i.e.scope, rel)
	h.open += 1
	return rel, nil
}

// Bind attaches a function to a host point. Declared in `define`; the
// host inserts it only after `activate` returns successfully (§8.1),
// which is why a failing activate leaves no live binding behind.
func (i *Inst) Bind(point string, fn BindFn, band int) error {
	if _, ok := i.h.points[point]; !ok {
		return Fail("plugin_point_unknown", "no such point: "+point,
			map[string]any{"point": point})
	}
	i.e.bindings = append(i.e.bindings, Bound{Ref: i.e.Ref, Point: point, Fn: fn, Band: band})
	return nil
}

// Export publishes a value for other plugins and for the application
// (§11).
func (i *Inst) Export(key string, value any) { i.e.exports[key] = value }

// Provides declares what this instance can do for others (§11.1).
func (i *Inst) Provides(p Provided) { i.e.provides = append(i.e.provides, p) }

type Position struct {
	Index     int  `json:"index"`
	Count     int  `json:"count"`
	Outermost bool `json:"outermost"`
	Innermost bool `json:"innermost"`
}

/* Position reports where this binding landed (§6.6) — the plugin-side
 * counterpart to a host pin. Station found that a plugin can need to
 * KNOW it is in the right place: its middleware must sit immediately
 * outside the base transport or its "wire truth" events are fiction.
 *
 * THE HOST DOES NOT POLICE THIS; it just makes the fact available. A
 * plugin that requires a position it did not get fails loudly rather
 * than reporting nonsense — and that is the plugin's call, because only
 * it knows what its position means. Verification tells a plugin it was
 * misplaced; a pin (§7) stops the misplacement from being expressible at
 * all. The two are not substitutes. */
func (i *Inst) Position(point string) (Position, error) {
	return i.h.PositionOf(i.e.Ref, point)
}

/* Nest: AN INSTANCE MAY ITSELF BE A HOST (§6.5), and THE OUTER ONE OWNS
 * THE INNER ONE'S LIFETIME. Registering the teardown in the instance
 * scope is what makes that true rather than aspirational: the inner host
 * closes when the outer instance deactivates, in the same reverse unwind
 * as every other resource. */
func (i *Inst) Nest(nestopts HostOptions) (*Host, error) {
	if !i.h.intransition {
		return nil, Fail("plugin_release_scope", "nest called outside a lifecycle callback", nil)
	}
	inner := MakeHost(nestopts)
	i.e.scope = append(i.e.scope, func() { inner.Close() })
	i.e.Inner = inner
	return inner, nil
}

// AutoTag is EXPLICIT (§4 rule 3). `Declare("stripe", {Tag: "?"})`
// assigns the LOWEST UNUSED POSITIVE INTEGER tag and returns the
// assigned pair. Without `"?"`, a collision is an error.
//
// It needs a host because it must know what is already declared, which
// is why it cannot live in the pure `ref` section — the correction P1.7
// made to §15.3.
func (h *Host) AutoTag(name string) (string, error) {
	for n := 1; ; n++ {
		cand, err := FormatRef(name, itoa(n))
		if nil != err {
			return "", err
		}
		if _, taken := h.inst[cand]; !taken {
			return cand, nil
		}
	}
}

type DeclareSpec struct {
	Definition string
	Options    map[string]any
	Order      *OrderBlock
	Pos        *int
	Tag        string
	// HostOwned is §9.1: "The host declares those instances itself,
	// after the user merge, and always wins." Set ONLY by HostDeclare.
	HostOwned bool
}

func (h *Host) Declare(ref string, spec DeclareSpec) (*Live, error) {
	if "?" == spec.Tag {
		r, err := CanonRef(ref)
		if nil != err {
			return nil, err
		}
		ref, err = h.AutoTag(refname(r))
		if nil != err {
			return nil, err
		}
	}
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	if !spec.HostOwned {
		if err := h.checkreserved(r); nil != err {
			return nil, err
		}
	}
	defname := or(spec.Definition, refname(r))
	def, ok := h.catalog.Get(defname)
	if !ok {
		return nil, Fail("plugin_unknown_definition", "not in catalog: "+defname,
			map[string]any{"name": defname})
	}

	if existing := h.inst[r]; nil != existing {
		// §4 rule 1: a pair addresses at most one instance. Re-declaring
		// the SAME definition is the idempotent case; a different one is
		// a duplicate, not a silent overwrite (seneca) and not an
		// impossibility (sdkgen).
		if existing.def.Name != def.Name {
			return nil, Fail("plugin_ref_duplicate", "instance already declared: "+r,
				map[string]any{"ref": r})
		}
		return existing, nil
	}

	pos := len(h.inst)
	if nil != spec.Pos {
		pos = *spec.Pos
	}
	options := spec.Options
	if nil == options {
		options = map[string]any{}
	}
	e := &Live{
		Ref: r, def: def, Status: StatusDeclared,
		Pos: pos, Seq: h.seqn,
		Options: options,
		State:   map[string]any{},
		order:   spec.Order, unmet: []string{}, scope: []func(){},
		bindings: []Bound{}, exports: map[string]any{}, provides: []Provided{},
	}
	h.seqn++
	h.inst[r] = e
	return e, nil
}

// HostDeclare is §9.1's host-owned path: a host that reserves a name
// MUST still be able to declare the instance it reserved.
//
// THE BOUNDARY IS BY METHOD, NOT BY CALLER, and that is a real limit: no
// language here can tell the embedding host from a plugin holding the
// same host object. What reservation protects is CONFIGURATION —
// documents, overlays, `VOXGIG_PLUGIN_*`, construction options and
// ordinary Declare/Load/Options — and all of that still checks.
func (h *Host) HostDeclare(ref string, spec DeclareSpec) (*Live, error) {
	if err := h.guard(); nil != err {
		return nil, err
	}
	spec.HostOwned = true
	return h.Declare(ref, spec)
}

func (h *Host) Load(ref string, spec DeclareSpec) (*Live, error) {
	if err := h.guard(); nil != err {
		return nil, err
	}
	e, err := h.Declare(ref, spec)
	if nil != err {
		return nil, err
	}
	if StatusDeclared != e.Status {
		return e, nil // idempotent in the trivial direction
	}
	if nil != spec.Options {
		e.Options = spec.Options
	}
	if err := h.run(e, e.def.Define, "define"); nil != err {
		e.Status = StatusFailed
		return nil, err
	}
	e.Status = StatusLoaded

	// AT LOAD, and before anything runs: a cycle through
	// restart-causing requirements does not settle, and the only safe
	// time to report a non-terminating reconcile is before it starts
	// (§11.3). `provides` is populated by `define`, which has just run,
	// so this is the first moment the graph is complete.
	if err := CheckCycle(h.graphnodes()); nil != err {
		e.Status = StatusFailed
		return nil, err
	}
	return e, nil
}

// graphnodes is the requirement graph as plain data, for the pure
// detector.
func (h *Host) graphnodes() []DependNode {
	out := []DependNode{}
	for _, r := range sortedkeys(h.inst) {
		names := []string{}
		for _, p := range h.inst[r].provides {
			names = append(names, p.Name)
		}
		out = append(out, DependNode{
			Ref: r, Provides: names, Requires: Requirements(h.inst[r].Options)})
	}
	return out
}

func (h *Host) Activate(ref string) (*Live, error) {
	if err := h.guard(); nil != err {
		return nil, err
	}
	e, err := h.need(ref)
	if nil != err {
		return nil, err
	}
	if StatusLive == e.Status {
		return e, nil // no-op returning success
	}
	if StatusFailed == e.Status {
		return nil, Fail("plugin_bad_state", "instance has failed: "+e.Ref,
			map[string]any{"ref": e.Ref})
	}
	if StatusDeclared == e.Status {
		if _, err := h.Load(e.Ref, DeclareSpec{}); nil != err {
			return nil, err
		}
	}

	// A declared requirement that is not live means `pending`:
	// activation is a STANDING REQUEST, not a one-shot event.
	if unmet := h.unmetof(e); 0 < len(unmet) {
		e.unmet = unmet
		e.Status = StatusPending
		return e, nil
	}

	if err := h.run(e, e.def.Activate, "activate"); nil != err {
		// Unwind whatever the partial activation captured, in reverse.
		h.unwind(e)
		e.Status = StatusFailed
		return nil, err
	}
	e.Status = StatusLive
	h.reconcile()
	return e, nil
}

func (h *Host) Deactivate(ref string) (*Live, error) {
	if err := h.guard(); nil != err {
		return nil, err
	}
	e, err := h.need(ref)
	if nil != err {
		return nil, err
	}
	if StatusLoaded == e.Status || StatusDeclared == e.Status {
		return e, nil
	}

	// §5.2: `Unload` is THE ONLY TRANSITION OUT OF `failed`.
	if StatusFailed == e.Status {
		return nil, Fail("plugin_bad_state", "instance has failed: "+e.Ref,
			map[string]any{"ref": e.Ref})
	}

	if StatusPending == e.Status {
		// DEACTIVATING A PENDING INSTANCE RUNS NO CALLBACK (§5.2). It
		// never reached activate, so it holds no scope and no live
		// bindings; running the definition's deactivate there would be
		// teardown without matching setup, which plugins are not written
		// to survive and which could fail an instance that had done
		// nothing wrong. It cannot fail.
		e.Status = StatusLoaded
		e.unmet = []string{}
		return e, nil
	}

	if err := h.held(e); nil != err {
		return nil, err
	}
	h.cascade(e, map[string]bool{})

	if err := h.run(e, e.def.Deactivate, "deactivate"); nil != err {
		h.unwind(e)
		e.Status = StatusFailed
		return nil, err
	}
	if err := h.releasecheck(e, h.unwind(e)); nil != err {
		return nil, err
	}
	e.Status = StatusLoaded
	h.reconcile()
	return e, nil
}

func (h *Host) Unload(ref string) error {
	if err := h.guard(); nil != err {
		return err
	}
	e, err := h.need(ref)
	if nil != err {
		return err
	}
	if StatusLive == e.Status || StatusPending == e.Status {
		if StatusLive == e.Status {
			if err := h.held(e); nil != err {
				return err
			}
			h.cascade(e, map[string]bool{})
			if err := h.run(e, e.def.Deactivate, "deactivate"); nil != err {
				// §5.2: ANY failure during a transition lands the
				// instance in `failed`, with the scope STILL FULLY
				// UNWOUND — and the instance STAYS REGISTERED, because
				// `failed` is a state an operator has to be able to see.
				h.unwind(e)
				e.Status = StatusFailed
				return err
			}
			if err := h.releasecheck(e, h.unwind(e)); nil != err {
				return err
			}
		}
		e.Status = StatusLoaded
	}
	if StatusLoaded == e.Status || StatusFailed == e.Status {
		err := h.run(e, e.def.Close, "close")
		delete(h.inst, e.Ref)
		return err
	}
	delete(h.inst, e.Ref)
	return nil
}

// Ready runs the whole forward path in one call (§5.1). §15.2's verb
// list omits this; §5.1 defines it and §15.3's `declare` row requires
// the corpus to pin it, so the list was incomplete rather than excluding
// it (DOCS.md §4.2).
func (h *Host) Ready(ref string) (*Live, error) {
	if err := h.guard(); nil != err {
		return nil, err
	}
	r, err := CanonRef(ref)
	if nil != err {
		return nil, err
	}
	if _, has := h.inst[r]; !has {
		if _, err := h.Declare(r, DeclareSpec{}); nil != err {
			return nil, err
		}
	}
	if StatusDeclared == h.inst[r].Status {
		if _, err := h.Load(r, DeclareSpec{}); nil != err {
			return nil, err
		}
	}
	return h.Activate(r)
}

// unwind: bindings go live only when activation succeeds (§8.1), so the
// teardown is the exact inverse: reverse order, always.
// unwind runs the scope in reverse and returns the errors it raised.
// §8.3: "A failing release does not stop the rest. Every entry runs, in
// reverse order, whatever any of them does; the errors are collected and
// raised as one `plugin_release_failed`."
//
// A Go release is `func()` and cannot return an error, so it signals
// failure by PANICKING — which is what a Go author's `defer f.Close()`
// wrapper does when it has nowhere to put the error, and which is
// recovered here rather than taking the host down.
func (h *Host) unwind(e *Live) []string {
	errors := []string{}
	for i := len(e.scope) - 1; 0 <= i; i-- {
		errors = append(errors, callrelease(e.scope[i])...)
	}
	e.scope = []func(){}
	return errors
}

func callrelease(fn func()) (out []string) {
	defer func() {
		if r := recover(); nil != r {
			out = []string{fmt.Sprint(r)}
		}
	}()
	fn()
	return nil
}

// releasecheck is §8.3: "A failed release ends the instance in `failed`,
// exactly as a failed callback does (§5.2) — a release that raised may
// have leaked, and an instance that may be holding resources it cannot
// account for must not be reactivated."
func (h *Host) releasecheck(e *Live, errors []string) error {
	if 0 == len(errors) {
		return nil
	}
	e.Status = StatusFailed
	return Fail("plugin_release_failed",
		"release failed for "+e.Ref+": "+join(errors, "; "),
		map[string]any{"ref": e.Ref, "cause": errors})
}

/* unmetof: A REQUIREMENT IS ON A CAPABILITY, not on a ref (§11.1) — it
 * is a dependency on something that can do the job, and which instance
 * is doing it is exactly the configuration detail a plugin must not care
 * about. A bare string is shorthand for `{name}`.
 *
 * A ref satisfies too, because a host that genuinely needs a specific
 * instance should not have to invent a capability for it. */
func (h *Host) unmetof(e *Live) []string {
	out := []string{}
	for _, r := range Requirements(e.Options) {
		if !GatesActivation(r) {
			continue
		}
		if 0 == len(h.providersof(r)) {
			out = append(out, r.Name)
		}
	}
	return out
}

/* boundproviders: the instance currently SELECTED for each of this one's
 * restart-causing requirements. A BINDING IS TO AN INSTANCE, not to a
 * capability (§11.1), and that is what decides behaviour when the bound
 * provider leaves while another match remains: the selected one going
 * away restarts a `static` consumer even though a survivor is available.
 * It is not silently re-pointed — `static` is the plugin saying in
 * writing that it cannot survive a provider swap, and a survivor being
 * available does not make the swap survivable. */
func (h *Host) boundproviders(e *Live) []string {
	out := []string{}
	for _, r := range Requirements(e.Options) {
		if !RestartsOnLoss(r) {
			continue
		}
		cands := h.providersof(r)
		if 0 < len(cands) && !hasstring(out, cands[0].Ref) {
			out = append(out, cands[0].Ref)
		}
	}
	return out
}

// consumersof: live instances whose selected provider is `ref` and which
// would be restarted by losing it.
func (h *Host) consumersof(ref string) []string {
	out := []string{}
	for _, r := range sortedkeys(h.inst) {
		c := h.inst[r]
		if r != ref && StatusLive == c.Status && hasstring(h.boundproviders(c), ref) {
			out = append(out, r)
		}
	}
	return out
}

func (h *Host) providersof(req Required) []Candidate {
	cands := []Candidate{}
	want := canon(req.Name)
	for _, ref := range sortedkeys(h.inst) {
		t := h.inst[ref]
		if StatusLive != t.Status {
			continue
		}
		// A ref satisfies directly.
		if ref == want {
			cands = append(cands, Candidate{Ref: ref, Pos: t.Pos, Provides: Provided{Name: req.Name}})
			continue
		}
		for _, p := range t.provides {
			if p.Name == req.Name {
				cands = append(cands, Candidate{Ref: ref, Pos: t.Pos, Provides: p})
			}
		}
	}
	return ResolveCapability(req, cands)
}

/* CONSUMERS GO DOWN FIRST, NOT AFTERWARDS (§11.3).
 *
 * The cascade is part of the provider's own deactivation and runs BEFORE
 * the provider's `deactivate` callback and scope unwind, so a consumer's
 * teardown can still call the thing it depends on — flushing a buffer to
 * the store it is about to lose is exactly what a `deactivate` callback
 * is for, and a cascade that fired after the provider was already gone
 * would make that impossible.
 *
 * Order: consumers deepest-first, then the provider. `Unload` and
 * `Close` inherit it, UNDER EITHER DEPENDENCY POLICY, which is what
 * makes apply's reverse-load-order teardown safe even when a document
 * happens to list a consumer before its provider. */
func (h *Host) cascade(provider *Live, seen map[string]bool) {
	if seen[provider.Ref] {
		return
	}
	seen[provider.Ref] = true

	for _, r := range h.consumersof(provider.Ref) {
		c := h.inst[r]
		if StatusLive != c.Status {
			continue
		}
		h.cascade(c, seen) // deepest-first
		bad := nil != h.run(c, c.def.Deactivate, "deactivate")
		errors := h.unwind(c)
		if bad || 0 < len(errors) {
			// §5.2: ANY failure during a transition lands the instance in
			// `failed`. Marking it `pending` handed it straight back to
			// `reconcile`, which would activate it again the moment the
			// provider returned.
			c.Status = StatusFailed
			continue
		}
		c.Status = StatusPending
		c.unmet = h.unmetof(c)
	}
}

/* held is A GUARD ON AD-HOC DEACTIVATION, NOT ON COORDINATED TEARDOWN.
 * In a bulk operation that is removing the holders too — `Close()`, or
 * an `Apply` plan whose own steps deactivate them — it is suspended for
 * exactly those holders, and the teardown still runs consumers before
 * providers.
 *
 * Otherwise `Close()` under `hold` would raise on the first provider it
 * reached whenever a document happened to list a consumer after it,
 * which is the policy refusing to allow the one teardown it has no
 * reason to object to. */
func (h *Host) held(e *Live) error {
	if "hold" != h.dependency {
		return nil
	}
	if h.coordinated {
		return nil
	}
	holders := h.consumersof(e.Ref)
	if 0 == len(holders) {
		return nil
	}
	return Fail("plugin_dependency_held",
		"instance is required by live consumers: "+e.Ref,
		map[string]any{"ref": e.Ref, "holders": holders})
}

/* reconcile is EAGER: run to a fixed point rather than scheduling.
 *
 * Two directions, and both are the reason `pending` exists. Activation
 * is a STANDING REQUEST, not a one-shot event: a pending instance whose
 * requirement arrives activates without being asked again, and a LIVE
 * instance whose requirement is lost goes back to pending —
 * recursively, through its own consumers. */
func (h *Host) reconcile() {
	rounds := 0
	for moved := true; moved; {
		moved = false
		rounds++
		if 1000 < rounds {
			break
		}

		// Losses first, so a cascade settles in one pass rather than
		// alternating with re-activations.
		for _, r := range sortedkeys(h.inst) {
			e := h.inst[r]
			if StatusLive != e.Status {
				continue
			}
			lost := []Required{}
			for _, q := range Requirements(e.Options) {
				if GatesActivation(q) && 0 == len(h.providersof(q)) {
					lost = append(lost, q)
				}
			}
			if 0 == len(lost) {
				continue
			}
			// POLICY IS PER REQUIREMENT, not per instance (§11.3): only
			// the definition that has the requirement knows what it can
			// cope with, and one instance may hold both a `static` and a
			// `dynamic` one. A `dynamic` requirement whose provider is
			// gone leaves the consumer LIVE and notified; it is a
			// statement about surviving a swap, so it does not restart
			// here.
			restarts := false
			for _, q := range lost {
				if RestartsOnLoss(q) {
					restarts = true
				}
			}
			if !restarts {
				continue
			}
			bad := nil != h.run(e, e.def.Deactivate, "deactivate")
			errors := h.unwind(e)
			if bad || 0 < len(errors) {
				e.Status = StatusFailed
				moved = true
				continue
			}
			e.Status = StatusPending
			e.unmet = h.unmetof(e)
			moved = true
		}

		for _, r := range sortedkeys(h.inst) {
			e := h.inst[r]
			if StatusPending != e.Status {
				continue
			}
			if 0 < len(h.unmetof(e)) {
				continue
			}
			if err := h.run(e, e.def.Activate, "activate"); nil != err {
				h.unwind(e)
				e.Status = StatusFailed
				moved = true
				continue
			}
			e.Status = StatusLive
			e.unmet = []string{}
			moved = true
		}
	}
}

// --- ordering --------------------------------------------------------

func (h *Host) Order(point string) ([]string, error) {
	bindings := []Binding{}
	for _, r := range sortedkeys(h.inst) {
		if StatusLive != h.inst[r].Status {
			continue
		}
		bindings = append(bindings, Binding{Ref: r, Pos: h.inst[r].Pos, Order: h.inst[r].order})
	}
	// The canonical builds this list from `Object.keys(inst)` —
	// INSERTION ORDER — and then sorts by (band, pos). Go maps have no
	// insertion order, so the list is built sorted by ref; the sort is
	// stable and total on (band, pos), and no two instances share a pos
	// unless a document set one explicitly.
	sort.SliceStable(bindings, func(i, j int) bool { return bindings[i].Pos < bindings[j].Pos })
	var pin Pin
	if "" != point {
		if spec, ok := h.points[point]; ok {
			pin = spec.Pin
		}
	}
	return ResolveOrder(bindings, pin)
}

// --- points ----------------------------------------------------------

// bound returns the live bindings on a point, in resolved order.
// Recomputed on any change to the live set (§7) rather than cached at
// startup — the bug a host discovers only when something deactivates in
// production.
func (h *Host) bound(point string) ([]Bound, error) {
	ranked, err := h.Order(point)
	if nil != err {
		return nil, err
	}
	out := []Bound{}
	for _, ref := range ranked {
		e := h.inst[ref]
		// The band is the INSTANCE's ordering block (§7), stamped by the
		// host. A plugin passing its own would be ranking itself above
		// the order its document declared.
		band := 0
		if nil != e.order && nil != e.order.Band {
			band = *e.order.Band
		}
		for _, b := range e.bindings {
			if b.Point == point {
				stamped := b
				stamped.Band = band
				out = append(out, stamped)
			}
		}
	}
	return out, nil
}

func (h *Host) pointspec(point string, want Kind) (Spec, error) {
	spec, ok := h.points[point]
	if !ok {
		return Spec{}, Fail("plugin_point_unknown", "no such point: "+point,
			map[string]any{"point": point})
	}
	if KindHook == want {
		// A point with no declared kind is a hook, which is what makes
		// `{}` the minimal point declaration.
		if "" != spec.Kind && KindHook != spec.Kind {
			return Spec{}, Fail("plugin_point_kind", "point is not a hook: "+point,
				map[string]any{"point": point, "kind": string(spec.Kind)})
		}
		return spec, nil
	}
	if spec.Kind != want {
		return Spec{}, Fail("plugin_point_kind", "point is not a "+string(want)+": "+point,
			map[string]any{"point": point, "kind": string(spec.Kind)})
	}
	return spec, nil
}

func (h *Host) Emit(point string, arg any) (any, error) {
	spec, err := h.pointspec(point, KindHook)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	mode := spec.Mode
	if "" == mode {
		mode = ModeEmit
	}
	return Emit(bindings, mode, arg)
}

func (h *Host) Call(point string, args ...any) (any, error) {
	spec, err := h.pointspec(point, KindChain)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	base := spec.Base
	if nil == base {
		base = func(a ...any) any {
			if 0 == len(a) {
				return nil
			}
			return a[0]
		}
	}
	return Compose(bindings, base)(args...), nil
}

func (h *Host) Provide(point string, args ...any) (any, error) {
	spec, err := h.pointspec(point, KindProvider)
	if nil != err {
		return nil, err
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	pick, err := Provider(bindings, spec)
	if nil != err {
		return nil, err
	}
	if nil == pick.Winner {
		return spec.Default, nil
	}
	return pick.Winner.Fn(args...), nil
}

// Shadowed makes the losers VISIBLE rather than silently ignored (§6.3).
func (h *Host) Shadowed(point string) ([]string, error) {
	spec, ok := h.points[point]
	if !ok {
		return []string{}, nil
	}
	bindings, err := h.bound(point)
	if nil != err {
		return nil, err
	}
	pick, err := Provider(bindings, spec)
	if nil != err {
		return nil, err
	}
	return pick.Shadowed, nil
}

func (h *Host) Exports(spec string) (any, error) {
	all := []Exported{}
	for _, ref := range sortedkeys(h.inst) {
		e := h.inst[ref]
		// Exports of a `loaded` (not live) instance are VISIBLE (§11).
		if StatusDeclared == e.Status || StatusFailed == e.Status {
			continue
		}
		for _, k := range sortedkeys(e.exports) {
			all = append(all, Exported{Ref: ref, Key: k, Value: e.exports[k]})
		}
	}
	return ResolveExport(spec, all)
}

// Capability lists the live providers of a capability, best-first
// (§11.1).
func (h *Host) Capability(name string) []string {
	cands := []Candidate{}
	for _, ref := range sortedkeys(h.inst) {
		e := h.inst[ref]
		if StatusLive != e.Status {
			continue
		}
		for _, p := range e.provides {
			if p.Name == name {
				cands = append(cands, Candidate{Ref: ref, Pos: e.Pos, Provides: p})
			}
		}
	}
	out := []string{}
	for _, c := range ResolveCapability(Required{Name: name}, cands) {
		out = append(out, c.Ref)
	}
	return out
}

// --- documents -------------------------------------------------------

// Apply is §9.6: "load what is missing, UNLOAD WHAT IS GONE, patch what
// changed, and move activation state to match", with the stated
// ordering — "deactivations and unloads first (reverse load order), then
// loads, then activations in load order".
//
// FOUR PHASES, NOT ONE INTERLEAVED LOOP. An earlier draft walked the
// document once, which never looked at instances the new document had
// DROPPED — so an integration removed from a config reload stayed live
// with its bindings and resources.
func (h *Host) Apply(doc any, profile string) error {
	if err := h.guard(); nil != err {
		return err
	}
	profile = or(profile, h.opts.Profile)
	norm, err := NormalizeConfig(NormalizeInput{
		Doc: doc, Profile: profile, Keys: h.opts.Keys, Reserved: h.reserved,
	})
	if nil != err {
		return err
	}

	want := norm.Order
	optionsof := map[string]map[string]any{}
	for _, ref := range want {
		options, err := ResolveOptions(ResolveInput{
			Ref: ref, Doc: doc, Profile: profile,
			Shape: h.shapeof(ref), HostDefaults: h.opts.Defaults[refname(ref)],
		})
		if nil != err {
			return err
		}
		optionsof[ref] = options
	}

	// wantlive: should this ref be LIVE after the apply? False for a ref
	// the document declares lazy or inactive AND for one it does not
	// name at all — which is what makes "unload what is gone" and
	// "unload what was toggled off" one rule rather than two.
	wantlive := func(ref string) bool {
		ent, has := norm.Instance[ref]
		return has && ent.Active && "eager" == ent.Start
	}

	// --- phase 1: deactivations and unloads, in REVERSE load order ---
	drop := []string{}
	for _, ref := range sortedkeys(h.inst) {
		if StatusDeclared == h.inst[ref].Status {
			continue
		}
		if !wantlive(ref) {
			drop = append(drop, ref)
		}
	}
	// Highest `pos` first, ref-descending for a tie, so a consumer
	// declared after its provider goes down first.
	sort.SliceStable(drop, func(i, j int) bool {
		a, b := h.inst[drop[i]], h.inst[drop[j]]
		if a.Pos != b.Pos {
			return a.Pos > b.Pos
		}
		return drop[i] > drop[j]
	})
	for _, ref := range drop {
		if err := h.Unload(ref); nil != err {
			return err
		}
	}

	// --- phase 2: declare and patch EVERYTHING, in load order --------
	for _, ref := range want {
		ent := norm.Instance[ref]
		pos := ent.Pos
		if _, err := h.Declare(ref, DeclareSpec{
			Options: optionsof[ref], Order: ent.Order, Pos: &pos}); nil != err {
			return err
		}
		// REFILL rather than REBIND. A definition's callbacks close over
		// the options map they were handed at `define`; replacing the
		// reference here would leave every binding reading the values the
		// first apply gave it.
		refill(h.inst[ref].Options, optionsof[ref])
		h.inst[ref].order = ent.Order
		h.inst[ref].Pos = ent.Pos
	}

	// --- phase 3: loads, in load order -------------------------------
	// ONLY THE EAGER, ACTIVE ONES: "a document of twenty lazy instances
	// is twenty map entries and no executed code" (§9.6).
	for _, ref := range want {
		if wantlive(ref) {
			if _, err := h.Load(ref, DeclareSpec{}); nil != err {
				return err
			}
		}
	}

	// --- phase 4: activations, in load order -------------------------
	for _, ref := range want {
		if wantlive(ref) {
			if _, err := h.Activate(ref); nil != err {
				return err
			}
		}
	}
	return nil
}

func (h *Host) shapeof(ref string) any {
	def, ok := h.catalog.Get(refname(ref))
	if !ok {
		return nil
	}
	return def.Shape
}

func (h *Host) SetOptions(ref string, patch map[string]any) error {
	if err := h.guard(); nil != err {
		return err
	}
	e, err := h.need(ref)
	if nil != err {
		return err
	}
	previous := map[string]any{}
	for k, v := range e.Options {
		previous[k] = v
	}
	resolved, err := ResolveOptions(ResolveInput{
		Ref: e.Ref, Shape: h.shapeof(e.Ref), Doc: map[string]any{},
		Patch: shallowmerge(previous, patch)})
	if nil != err {
		return err
	}
	refill(e.Options, resolved)
	if StatusLive == e.Status {
		if nil != e.def.Reconfigure {
			h.intransition = true
			err := e.def.Reconfigure(h.api(e), e.Options, previous)
			h.intransition = false
			return err
		}
		// Always correct and sometimes expensive; `reconfigure` exists
		// to make the common case cheap (§9.4).
		if _, err := h.Deactivate(e.Ref); nil != err {
			return err
		}
		if _, err := h.Activate(e.Ref); nil != err {
			return err
		}
	}
	return nil
}

// refill empties the target and refills it, so callers holding the
// reference see the new values.
func refill(target map[string]any, source map[string]any) {
	for k := range target {
		delete(target, k)
	}
	for k, v := range source {
		target[k] = v
	}
}

func shallowmerge(a map[string]any, b map[string]any) map[string]any {
	out := map[string]any{}
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

func (h *Host) Close() error {
	// A bulk teardown removing the holders too, so `hold` is suspended
	// for exactly those holders (§11.3) - while the consumers-first
	// cascade still runs, which is the half that matters.
	h.coordinated = true
	defer func() { h.coordinated = false }()
	refs := sortedkeys(h.inst)
	for i := len(refs) - 1; 0 <= i; i-- {
		if err := h.Unload(refs[i]); nil != err {
			return err
		}
	}
	return nil
}

// PositionOf is the same record §6.6 gives a plugin about itself,
// reachable from outside for the corpus. A plugin asks via
// `inst.Position(point)`.
func (h *Host) PositionOf(ref string, point string) (Position, error) {
	e := h.inst[canon(ref)]
	if nil == e {
		return Position{}, Fail("plugin_not_loaded", "no such instance: "+ref,
			map[string]any{"ref": ref})
	}
	ranked, err := h.Order(point)
	if nil != err {
		return Position{}, err
	}
	index := indexof(ranked, e.Ref)
	return Position{
		Index: index, Count: len(ranked),
		// §6.2 composes b1(b2(b3(base))) with the FIRST binding
		// OUTERMOST, so these are not index 0 and index count-1 the
		// other way round. Getting this backwards is the exact error the
		// positional pin vocabulary exists to prevent.
		Outermost: 0 == index,
		Innermost: index == len(ranked)-1,
	}, nil
}

// Define adds a definition to this host's catalog.
func (h *Host) Define(def Definition) error { return h.catalog.Add(def) }
