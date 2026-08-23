/* `ref` — the first section a port passes. */

package plugintest

import (
	"testing"

	plugin "github.com/voxgig/plugin/go/plugin"
)

func str(v any) string { s, _ := v.(string); return s }

func arg(e Entry, i int) string {
	if i < len(e.Args) {
		return str(e.Args[i])
	}
	return ""
}

// SUBJECT maps a group name to the function under test. Explicit rather
// than inferred: a runner that guessed from the entry's shape would run
// the wrong function on a mistyped entry.
var refSubject = map[string]func(Entry) (any, error){
	"parse":    func(e Entry) (any, error) { return plugin.ParseRef(str(e.In)) },
	"parsebad": func(e Entry) (any, error) { return plugin.ParseRef(str(e.In)) },
	"format":   func(e Entry) (any, error) { return plugin.FormatRef(arg(e, 0), arg(e, 1)) },
	"formatbad": func(e Entry) (any, error) {
		return plugin.FormatRef(arg(e, 0), arg(e, 1))
	},
	"canon":    func(e Entry) (any, error) { return plugin.CanonRef(str(e.In)) },
	"name":     func(e Entry) (any, error) { return plugin.CheckName(str(e.In)), nil },
	"tag":      func(e Entry) (any, error) { return plugin.CheckTag(str(e.In)), nil },
	"bound":    func(e Entry) (any, error) { return plugin.CheckName(str(e.In)), nil },
	"boundtag": func(e Entry) (any, error) { return plugin.CheckTag(str(e.In)), nil },
}

func TestRef(t *testing.T) {
	runsection(t, "ref", refSubject)
}

// runsection is the whole of every pure section's test: dispatch every
// group, and fail on a group the runner does not know — a group silently
// not run is worse than a failure.
func runsection(t *testing.T, name string, subject map[string]func(Entry) (any, error)) {
	t.Helper()
	groups, err := Section(name)
	if nil != err {
		t.Fatalf("%s: %v", name, err)
	}

	for _, g := range Groups(groups) {
		fn, ok := subject[g]
		if !ok {
			t.Errorf("%s: corpus group with no subject: %s", name, g)
			continue
		}
		g, fn := g, fn
		t.Run(name+"/"+g, func(t *testing.T) {
			for i, e := range groups[g] {
				if why := Check(e, fn); "" != why {
					t.Errorf("%s: %s", Label(g, i, e), why)
				}
			}
		})
	}
}
