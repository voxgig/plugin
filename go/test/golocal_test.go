package plugintest

import (
	"sync"
	"testing"

	plugin "github.com/voxgig/plugin/go/plugin"
)

func TestCapabilityMatchesAcrossNumberTypes(t *testing.T) {
	cands := []plugin.Candidate{{
		Ref: "store$a", Pos: 0,
		Provides: plugin.Provided{
			Name: "store", Version: "1.0.0",
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
