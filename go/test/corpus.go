/* The corpus runner.
 *
 * Reads spec/plugin.json — the COMMITTED artifact, not the aontu source
 * — exactly as every other port's runner does. No port needs a Node
 * toolchain to run its tests, and this one does not get a private door
 * into the source either.
 *
 * A group name selects the subject. That is the whole dispatch, and it
 * is deliberately dumb: a runner that inferred the subject from the
 * entry's shape would silently run the wrong function when an entry was
 * mistyped.
 *
 * COMPARISON RUNS OVER JSON-NORMALIZED VALUES. A typed port's result is
 * a struct; the corpus's expectation is decoded JSON. Marshalling the
 * result and decoding it back puts both on the same footing — and it is
 * also the honest test, because a field the port forgot to tag is a
 * field a caller cannot see either. */

package plugintest

import (
	"encoding/json"
	"os"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"

	plugin "github.com/voxgig/plugin/go/plugin"
)

type Entry struct {
	ID    string
	Doc   bool
	In    any
	Args  []any
	Ctx   any
	Cmd   []any
	Out   any
	Err   any
	Match any
	// raw keeps PRESENCE, which the three legal field combinations turn
	// on: `out: null` is an assertion and an absent `out` is not.
	raw map[string]any
}

func (e Entry) has(key string) bool { _, ok := e.raw[key]; return ok }

func specpath() string {
	_, self, _, _ := runtime.Caller(0)
	return filepath.Join(filepath.Dir(self), "..", "..", "spec", "plugin.json")
}

func Corpus() (map[string]any, error) {
	data, err := os.ReadFile(specpath())
	if nil != err {
		return nil, err
	}
	var out map[string]any
	if err := json.Unmarshal(data, &out); nil != err {
		return nil, err
	}
	return out, nil
}

// Section returns one corpus section's groups, each a list of entries.
func Section(name string) (map[string][]Entry, error) {
	spec, err := Corpus()
	if nil != err {
		return nil, err
	}
	primary, _ := spec["primary"].(map[string]any)
	sec, ok := primary[name].(map[string]any)
	if !ok {
		return nil, os.ErrNotExist
	}
	out := map[string][]Entry{}
	for g, raw := range sec {
		if "DEF" == g {
			continue
		}
		group, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		set, ok := group["set"].([]any)
		if !ok {
			continue
		}
		entries := []Entry{}
		for _, item := range set {
			m, ok := item.(map[string]any)
			if !ok {
				continue
			}
			entries = append(entries, entryof(m))
		}
		out[g] = entries
	}
	return out, nil
}

func entryof(m map[string]any) Entry {
	e := Entry{raw: m}
	e.ID, _ = m["id"].(string)
	e.Doc, _ = m["doc"].(bool)
	e.In = m["in"]
	if l, ok := m["args"].([]any); ok {
		e.Args = l
	}
	e.Ctx = m["ctx"]
	if l, ok := m["cmd"].([]any); ok {
		e.Cmd = l
	}
	e.Out = m["out"]
	e.Err = m["err"]
	e.Match = m["match"]
	return e
}

// Groups is every group name in a section, sorted — so a failure names
// the same group in the same place on every run.
func Groups(groups map[string][]Entry) []string {
	out := make([]string, 0, len(groups))
	for g := range groups {
		out = append(out, g)
	}
	sort.Strings(out)
	return out
}

// Label is a stable label, so a failure names the entry rather than an
// index.
func Label(group string, i int, e Entry) string {
	if "" != e.ID {
		return e.ID
	}
	return group + "#" + itoa(i)
}

// Normalize puts a Go value on the same footing as a decoded corpus
// value: JSON out, JSON back.
func Normalize(v any) any {
	data, err := json.Marshal(v)
	if nil != err {
		return v
	}
	var out any
	if err := json.Unmarshal(data, &out); nil != err {
		return v
	}
	return out
}

// Equal is deep equality over spec values. Key order never matters; list
// order always does.
func Equal(a any, b any) bool {
	am, aok := a.(map[string]any)
	bm, bok := b.(map[string]any)
	if aok && bok {
		if len(am) != len(bm) {
			return false
		}
		for k, av := range am {
			bv, has := bm[k]
			if !has || !Equal(av, bv) {
				return false
			}
		}
		return true
	}
	al, aok := a.([]any)
	bl, bok := b.([]any)
	if aok || bok {
		if !aok || !bok || len(al) != len(bl) {
			return false
		}
		for i := range al {
			if !Equal(al[i], bl[i]) {
				return false
			}
		}
		return true
	}
	return a == b
}

/* Matches is a partial match: every key the expectation names must
 * agree, and keys it does not name are ignored. `__EXISTS__` asserts
 * presence without pinning a value; `/re/` matches a string as a regular
 * expression.
 *
 * `present` carries what JavaScript gets from `undefined` for free: a
 * key that is absent and a key holding JSON `null` are different, and a
 * Go map lookup collapses them. */
func Matches(expect any, actual any, present bool) bool {
	if s, ok := expect.(string); ok {
		switch s {
		case "__EXISTS__":
			return present && nil != actual
		case "__UNDEF__":
			return !present
		case "__NULL__":
			return present && nil == actual
		}
		if 2 < len(s) && strings.HasPrefix(s, "/") && strings.HasSuffix(s, "/") {
			str, ok := actual.(string)
			if !ok {
				return false
			}
			re, err := regexp.Compile(s[1 : len(s)-1])
			if nil != err {
				return false
			}
			return re.MatchString(str)
		}
	}

	if el, ok := expect.([]any); ok {
		al, ok := actual.([]any)
		if !ok || len(el) != len(al) {
			return false
		}
		for i := range el {
			if !Matches(el[i], al[i], true) {
				return false
			}
		}
		return true
	}

	if em, ok := expect.(map[string]any); ok {
		am, ok := actual.(map[string]any)
		if !ok {
			return false
		}
		for _, k := range sortedkeys(em) {
			av, has := am[k]
			if !Matches(em[k], av, has) {
				return false
			}
		}
		return true
	}

	return expect == actual
}

/* Check runs one entry against a subject and reports the disagreement,
 * if any.
 *
 * The three combinations the spec format allows are enforced here as
 * well as at build time, because a runner that quietly accepted `err`
 * beside `out` would let a contradictory entry pass. */
func Check(e Entry, subject func(Entry) (any, error)) string {
	if e.has("err") && e.has("out") {
		return "entry has both err and out"
	}

	value, raised := subject(e)

	if e.has("err") {
		if nil == raised {
			return "expected a raise, got: " + jsonof(value)
		}
		if want, ok := e.Err.(string); ok {
			// Errors compare by CODE (§12). Message wording is a port's
			// own business, and pinning it would make every translation
			// a corpus change.
			if got := plugin.CodeOf(raised); got != want {
				return "expected code " + want + ", got " + got + " (" + raised.Error() + ")"
			}
		}
		if e.has("match") {
			got := map[string]any{"err": map[string]any{
				"code":    plugin.CodeOf(raised),
				"message": raised.Error(),
				"name":    "PluginError",
			}}
			if !Matches(e.Match, got, true) {
				return "error did not match " + jsonof(e.Match) + ", got " + jsonof(got)
			}
		}
		return ""
	}

	if nil != raised {
		return "unexpected raise: " + plugin.CodeOf(raised) + " " + raised.Error()
	}

	out := Normalize(value)

	if e.has("out") {
		if !Equal(e.Out, out) {
			return "expected " + jsonof(e.Out) + ", got " + jsonof(out)
		}
	}

	if e.has("match") {
		got := map[string]any{"in": e.In, "out": out}
		if !Matches(e.Match, got, true) {
			return "did not match " + jsonof(e.Match) + ", got out=" + jsonof(out)
		}
	}

	if !e.has("out") && !e.has("match") {
		return "entry asserts nothing"
	}

	return ""
}

// decode re-marshals a corpus value into a typed input. The struct tags
// ARE the contract here: a field the port spelled differently from the
// corpus arrives zero, and the entry fails — which is the check a
// dynamically-typed port gets for free and a typed one has to arrange.
func decode(v any, target any) error {
	data, err := json.Marshal(v)
	if nil != err {
		return err
	}
	return json.Unmarshal(data, target)
}

func jsonof(v any) string {
	data, err := json.Marshal(v)
	if nil != err {
		return "?"
	}
	return string(data)
}

func sortedkeys[V any](m map[string]V) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func itoa(n int) string {
	if 0 == n {
		return "0"
	}
	neg := 0 > n
	if neg {
		n = -n
	}
	digits := ""
	for 0 < n {
		digits = string(rune('0'+n%10)) + digits
		n /= 10
	}
	if neg {
		return "-" + digits
	}
	return digits
}
