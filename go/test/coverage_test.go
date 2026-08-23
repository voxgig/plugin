/* EVERY CORPUS SECTION IS RUN.
 *
 * The per-section tests already fail on a GROUP with no subject. This
 * closes the level above: a whole SECTION the runner never mentions is
 * a section silently not run, and it would pass a suite that claims
 * P4's exit ("both pass every corpus section").
 *
 * It also counts the entries, so a section that decodes to an empty set
 * cannot masquerade as a passing one. */

package plugintest

import (
	"sort"
	"testing"
)

// pureSections are the sections driven by a direct function call; the
// names must match the map keys the pure tests dispatch.
var pureSections = []string{
	"ref", "env", "version", "capability", "graph", "resolve", "config",
}

func TestEverySectionIsRun(t *testing.T) {
	spec, err := Corpus()
	if nil != err {
		t.Fatalf("corpus: %v", err)
	}
	primary, ok := spec["primary"].(map[string]any)
	if !ok {
		t.Fatal("corpus has no primary block")
	}

	// The corpus metadata block is what turns on strict entry
	// validation in every runner, so a corpus that lost it must not
	// silently downgrade this port's checking.
	meta, _ := spec["PLUGIN"].(map[string]any)
	if v, _ := meta["version"].(float64); 1 != v {
		t.Fatalf("corpus PLUGIN.version is %v, want 1", meta["version"])
	}

	run := map[string]bool{}
	for _, s := range pureSections {
		run[s] = true
	}
	for _, s := range driverSections {
		run[s] = true
	}

	missing := []string{}
	for name := range primary {
		if !run[name] {
			missing = append(missing, name)
		}
	}
	sort.Strings(missing)
	if 0 < len(missing) {
		t.Errorf("corpus sections no test runs: %v", missing)
	}

	extra := []string{}
	total := 0
	for name := range run {
		groups, err := Section(name)
		if nil != err {
			extra = append(extra, name)
			continue
		}
		n := 0
		for _, g := range Groups(groups) {
			n += len(groups[g])
		}
		if 0 == n {
			t.Errorf("section %s decoded to no entries", name)
		}
		total += n
	}
	sort.Strings(extra)
	if 0 < len(extra) {
		t.Errorf("tests name sections the corpus does not have: %v", extra)
	}

	// A floor, not a fixture: the corpus grows, and a run that suddenly
	// covers a fraction of it is the failure worth catching.
	if 400 > total {
		t.Errorf("only %d corpus entries reachable; the corpus has far more", total)
	}
	t.Logf("go port: %d corpus entries across %d sections", total, len(run))
}
