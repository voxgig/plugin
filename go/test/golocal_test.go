/* THE TWO THINGS THE CORPUS STRUCTURALLY CANNOT SEE.
 *
 * Every other test in this directory is corpus-driven, and that is the
 * rule: the corpus is the contract, and a port-local test is a way to
 * disagree with it quietly. These two are the exception the rule needs,
 * because neither claim is EXPRESSIBLE in a language-neutral JSON
 * corpus:
 *
 *   - the corpus decodes every number as `float64`, so it cannot ask
 *     what happens when a Go host writes an `int`; and
 *   - the corpus is single-threaded, so it cannot ask what two
 *     goroutines do.
 *
 * Both were found by review rather than by a failing entry, which is
 * exactly why they are written down here. Neither adds a rule; each
 * pins a rule the model already states, in the one dimension Go has
 * and the corpus does not. */

package plugintest

import (
	"sync"
	"testing"

	plugin "github.com/voxgig/plugin/go/plugin"
)

// A Go host declares attributes in Go, not in JSON — so `5` is an `int`
// while the requirement it must satisfy, read from a document, is a
// `float64`. The model has ONE number type; matching across Go's
// spellings of it is not leniency, it is the model.
func TestCapabilityMatchesAcrossNumberTypes(t *testing.T) {
	cands := []plugin.Candidate{{
		Ref: "store$a", Pos: 0,
		Provides: plugin.Provided{
			Name: "store", Version: "1.0.0",
			// int, uint and float32 — three spellings of one value.
			Attrs: map[string]any{"max": 5, "min": uint(1), "rate": float32(2)},
		},
	}}

	req := plugin.Required{
		Name: "store", Range: "1.0",
		// float64, as every JSON decode produces.
		Match: map[string]any{"max": 5.0, "min": 1.0, "rate": 2.0},
	}
	if 1 != len(plugin.ResolveCapability(req, cands)) {
		t.Fatalf("a float64 requirement must match an int attribute")
	}

	// ...and the KINDS stay strict. `true` is not `1` in any port.
	bools := []plugin.Candidate{{
		Ref: "store$b", Pos: 0,
		Provides: plugin.Provided{
			Name: "store", Version: "1.0.0",
			Attrs: map[string]any{"on": true},
		},
	}}
	numeric := plugin.Required{
		Name: "store", Range: "1.0", Match: map[string]any{"on": 1.0}}
	if 0 != len(plugin.ResolveCapability(numeric, bools)) {
		t.Fatalf("a numeric requirement must not match a boolean attribute")
	}

	// ...and a value that differs still misses.
	off := plugin.Required{
		Name: "store", Range: "1.0", Match: map[string]any{"max": 6.0}}
	if 0 != len(plugin.ResolveCapability(off, cands)) {
		t.Fatalf("a different value must not match")
	}
}

// §5.2 makes transitions SEQUENTIAL. `intransition` alone could not
// deliver that — it is set inside `run`, so two goroutines both passed
// the guard — and the damage was to the registry itself: `Declare`
// reads `len(h.inst)` for `Pos` and `h.seqn` for `Seq`, so an
// interleaved pair produced two instances sharing both.
//
// -race is what makes this test worth having; `make test` runs it.
func TestConcurrentDeclaresAreSequential(t *testing.T) {
	host := plugin.MakeHost(plugin.HostOptions{
		Catalog: withprobes(), Points: withpoints(nil)})

	const N = 32
	refs := []string{}
	for i := 0; i < N; i++ {
		refs = append(refs, "probe$t"+itoa(i))
	}

	var wg sync.WaitGroup
	errs := make([]error, N)
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(k int) {
			defer wg.Done()
			_, errs[k] = host.Declare(refs[k], plugin.DeclareSpec{})
		}(i)
	}
	wg.Wait()

	for i, err := range errs {
		if nil != err {
			t.Fatalf("declare %s: %v", refs[i], err)
		}
	}

	// Every instance landed, and no two share a seq or a pos — which is
	// the observable form of "one at a time".
	list := host.List()
	if N != len(list) {
		t.Fatalf("expected %d instances, got %d", N, len(list))
	}
	seqs := map[int]string{}
	poss := map[int]string{}
	for _, r := range refs {
		e, err := host.Instance(r)
		if nil != err || nil == e {
			t.Fatalf("instance %s: %v", r, err)
		}
		if prev, dup := seqs[e.Seq]; dup {
			t.Fatalf("seq %d shared by %s and %s", e.Seq, prev, r)
		}
		seqs[e.Seq] = r
		if prev, dup := poss[e.Pos]; dup {
			t.Fatalf("pos %d shared by %s and %s", e.Pos, prev, r)
		}
		poss[e.Pos] = r
	}
}
