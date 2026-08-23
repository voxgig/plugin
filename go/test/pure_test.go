/* The P2 pure sections: env, version, capability, graph, resolve — plus
 * config, whose two functions the group name selects. */

package plugintest

import (
	"strings"
	"testing"

	plugin "github.com/voxgig/plugin/go/plugin"
)

func TestEnv(t *testing.T) {
	run := func(e Entry) (any, error) {
		var in plugin.EnvInput
		if err := decode(e.In, &in); nil != err {
			return nil, err
		}
		return plugin.ApplyEnv(in)
	}
	runsection(t, "env", map[string]func(Entry) (any, error){
		"option": run, "value": run, "toggle": run,
		"profile": run, "ambiguous": run, "reserved": run,
	})
}

func TestVersion(t *testing.T) {
	rng := func(e Entry) (any, error) { return plugin.ParseRange(str(e.In)) }
	runsection(t, "version", map[string]func(Entry) (any, error){
		"range":    rng,
		"rangebad": rng,
		"satisfies": func(e Entry) (any, error) {
			in, _ := e.In.(map[string]any)
			return plugin.Satisfies(str(in["version"]), str(in["range"]))
		},
	})
}

func TestCapability(t *testing.T) {
	run := func(e Entry) (any, error) {
		var in struct {
			Req        plugin.Required    `json:"req"`
			Candidates []plugin.Candidate `json:"candidates"`
		}
		if err := decode(e.In, &in); nil != err {
			return nil, err
		}
		return plugin.ResolveCapability(in.Req, in.Candidates), nil
	}
	runsection(t, "capability", map[string]func(Entry) (any, error){
		"match": run, "rank": run, "nested": run,
	})
}

func TestGraph(t *testing.T) {
	run := func(e Entry) (any, error) {
		var nodes []plugin.Node
		if err := decode(e.In, &nodes); nil != err {
			return nil, err
		}
		return plugin.ResolveGraph(nodes), nil
	}
	runsection(t, "graph", map[string]func(Entry) (any, error){
		"resolve": run, "blocked": run,
	})
}

func TestResolve(t *testing.T) {
	runsection(t, "resolve", map[string]func(Entry) (any, error){
		"candidates": func(e Entry) (any, error) {
			var in struct {
				Name    string          `json:"name"`
				Sources []plugin.Source `json:"sources"`
			}
			if err := decode(e.In, &in); nil != err {
				return nil, err
			}
			return plugin.ResolveCandidates(in.Name, in.Sources), nil
		},
		"from": func(e Entry) (any, error) { return plugin.ResolveFrom(str(e.In)), nil },
	})
}

func TestConfig(t *testing.T) {
	groups, err := Section("config")
	if nil != err {
		t.Fatalf("config: %v", err)
	}

	norm := func(e Entry) (any, error) {
		var in plugin.NormalizeInput
		if err := decode(e.In, &in); nil != err {
			return nil, err
		}
		return plugin.NormalizeConfig(in)
	}
	opts := func(e Entry) (any, error) {
		var in plugin.ResolveInput
		if err := decode(e.In, &in); nil != err {
			return nil, err
		}
		return plugin.ResolveOptions(in)
	}

	for _, g := range Groups(groups) {
		var fn func(Entry) (any, error)
		if strings.HasPrefix(g, "norm") {
			fn = norm
		} else if strings.HasPrefix(g, "opt") {
			fn = opts
		} else {
			t.Errorf("config: corpus group with no subject: %s", g)
			continue
		}
		g, fn := g, fn
		t.Run("config/"+g, func(t *testing.T) {
			for i, e := range groups[g] {
				if why := Check(e, fn); "" != why {
					t.Errorf("%s: %s", Label(g, i, e), why)
				}
			}
		})
	}
}
