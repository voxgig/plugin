/* Shared types. Deliberately small: the design's §19 budget says the
 * library owns naming, configuration, lifecycle, ordering, binding and
 * teardown, and nothing else.
 *
 * GO IS THE FIRST PORT AND IT CHANGES ONE THING ON PURPOSE (§18, P4):
 * errors are RETURNED, not raised. The canonical raises, and every
 * signature that could fail here returns `error` instead. That is the
 * point of porting Go first — "static-only + typed extension points +
 * explicit errors will find every TypeScript-shaped assumption in the
 * model" — and the corpus compares by CODE, which survives the change
 * intact. */

package plugin

import (
	"bytes"
	"encoding/json"
	"fmt"
)

// Ref is the two halves of an identity (§4). Tag is "" when absent —
// never nil and never missing, because a port returning three shapes
// for two states makes every downstream comparison a special case.
type Ref struct {
	Name string `json:"name"`
	Tag  string `json:"tag"`
}

// Status is one of §5.1's seven statuses, and no more. A port that adds
// an eighth is diverging. `loading` and `closing` are observable only
// from inside a callback or from another thread.
type Status string

const (
	StatusDeclared Status = "declared"
	StatusLoaded   Status = "loaded"
	StatusPending  Status = "pending"
	StatusLive     Status = "live"
	StatusFailed   Status = "failed"
	StatusLoading  Status = "loading"
	StatusClosing  Status = "closing"
)

// OrderBlock is §4.4 of DOCS.md — `band` rather than a nested `order`,
// because `order.order` needs explaining every time it is read.
type OrderBlock struct {
	Before OrderRef `json:"before,omitempty"`
	After  OrderRef `json:"after,omitempty"`
	Band   *int     `json:"band,omitempty"`
}

// MarshalJSON omits an unstated constraint entirely.
//
// `omitempty` does not apply to a struct, so without this an absent
// `before` serialized as `"before": null` while canonical simply has no
// key - the same language-dependent shape divergence as emitting a list
// for an authored scalar, one level up.
func (block OrderBlock) MarshalJSON() ([]byte, error) {
	out := map[string]any{}
	if block.Before.set {
		out["before"] = block.Before
	}
	if block.After.set {
		out["after"] = block.After
	}
	if nil != block.Band {
		out["band"] = *block.Band
	}

	return json.Marshal(out)
}

// OrderRef is ONE spelling or a LIST of them.
//
// plugin used to type this as a bare string, so a list matched nothing and
// was SILENTLY DROPPED - the sort came out as if no constraint had been
// declared. Go could not even represent the input.
//
// `raw` is THE AUTHORED VALUE, kept so normalization can hand the block
// back exactly as written; `List` is the parsed form the sort consumes,
// and `set` says whether the key was stated at all. Canonical does not
// need any of this: it never decodes the block, it assigns it (`ent.order
// = ord`), so every spelling survives untouched. Go is the only port that
// decodes and rebuilds, and a rebuild silently loses whatever it does not
// model. That single cause produced four separate parity breaks - the
// list form, scalar-vs-one-element-list, an authored empty list, an
// authored null - and the corpus could see none of them until
// `config/normorder` was written to assert the block's own shape.
//
// `set` is deliberately not `0 < len(List)`: an authored `[]` states a
// constraint that names nothing, which is NOT the same document as an
// absent key.
type OrderRef struct {
	List []string
	raw  any
	set  bool
}

// UnmarshalJSON decodes to `any` first and then goes through the SAME
// decoder the in-memory path uses.
//
// It used to try `string` and then `[]string` directly. That is wrong
// twice over: json.Unmarshal into a string is a documented NO-OP on JSON
// null and returns a nil error, so `{"after":null}` took the string
// branch and came back as `{"after":""}` - an empty-string constraint
// nobody wrote; and having two decoders for one rule let them drift, so
// this path hard-failed on values the in-memory path quietly accepted.
func (ref *OrderRef) UnmarshalJSON(data []byte) error {
	var authored any

	if err := json.Unmarshal(data, &authored); nil != err {
		return err
	}

	*ref = asorderref(authored, true)

	return nil
}

// MarshalJSON replays the authored value.
func (ref OrderRef) MarshalJSON() ([]byte, error) {
	if !ref.set {
		return []byte("null"), nil
	}

	return json.Marshal(ref.raw)
}

// Instance is a normalized instance entry. Option data is NOT merged
// here — see OptionLayers.
type Instance struct {
	Pos    int         `json:"pos"`
	Active bool        `json:"active"`
	Start  string      `json:"start"`
	Order  *OrderBlock `json:"order,omitempty"`
	// OptionLayers holds levels 3-6 that are present, IN LADDER ORDER
	// (§9.3).
	//
	// Normalization does not merge these, and cannot: §9.4 makes merge
	// behaviour a property of the definition's option shape, which
	// normalization has never seen. Flattening them here would make
	// `$MERGE: append` unimplementable at load time, because the layers
	// it must concatenate would already be collapsed.
	OptionLayers []any `json:"optionlayers"`
}

type Normalized struct {
	Instance map[string]*Instance `json:"instance"`
	Order    []string             `json:"order"`
	Default  map[string]any       `json:"default"`
}

// DetailOrder is §12's detail fields, IN THIS FIXED ORDER.
//
// The order is part of the contract, not a formatting preference. An
// earlier draft named six fields while other sections promised
// diagnostics that had nowhere to go, which would have left each port
// inventing its own order and breaking message parity.
var DetailOrder = []string{
	"host", "ref", "name", "tag", "point", "key", "capability",
	"range", "version", "match", "candidates", "cycle", "holders",
	"refs", "path", "cause",
}

// compactjson renders a value the way JSON.stringify does: compact, and
// WITHOUT Go's default HTML escaping, which would turn `<` into `<`
// and break message parity against every other port.
func compactjson(v any) string {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(v); nil != err {
		return fmt.Sprintf("%v", v)
	}
	return string(bytes.TrimRight(buf.Bytes(), "\n"))
}

// FormatError renders `plugin/<code>: <text> [<key>=<value> …]`.
//
// Values render as COMPACT JSON, so a value containing a space or a
// bracket cannot break the parse, and a list renders as a JSON array.
// The bracket is absent entirely when no field applies.
func FormatError(code string, text string, details map[string]any) string {
	parts := []string{}
	for _, k := range DetailOrder {
		v, ok := details[k]
		if !ok {
			continue
		}
		parts = append(parts, k+"="+compactjson(v))
	}
	tail := ""
	if 0 < len(parts) {
		tail = " ["
		for i, p := range parts {
			if 0 < i {
				tail += " "
			}
			tail += p
		}
		tail += "]"
	}
	return "plugin/" + code + ": " + text + tail
}

// PluginError carries a §12 code. Ports compare by CODE and never by
// message: wording is a port's own business, and pinning the words would
// make every translation a corpus change. The FORMAT, however, is
// pinned — a parseable message is what makes a log searchable across
// twenty languages.
type PluginError struct {
	Code    string
	Text    string
	Details map[string]any
	message string
}

func (e *PluginError) Error() string { return e.message }

// Fail builds the error the canonical would have thrown. Go RETURNS it;
// every caller in this port propagates rather than unwinding.
func Fail(code string, text string, details map[string]any) *PluginError {
	if nil == details {
		details = map[string]any{}
	}
	return &PluginError{
		Code:    code,
		Text:    text,
		Details: details,
		message: FormatError(code, text, details),
	}
}

// CodeOf reports the §12 code of an error, or "" for an error this
// library did not raise. The corpus compares by code, so the driver
// needs one place that knows how to read it.
func CodeOf(err error) string {
	if pe, ok := err.(*PluginError); ok {
		return pe.Code
	}
	return ""
}
