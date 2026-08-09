// Package component reads the contract in components/ — the one interface the
// Lua configuration and this CLI share.
//
// The rules here must match lua/chroma/components.lua. Where they disagree, one
// side accepts a contract the other rejects, and the disagreement surfaces
// during an install rather than in a test. That is why the shipped contract is
// checked by both.
package component

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Contract is the version this CLI understands. A component declaring a higher
// one was written for a newer Chroma; reading it anyway is how the two sides
// drift apart quietly. See cli/DESIGN.md, "The component contract".
const Contract = 5

// Version is a compatibility boundary, and only that.
//
// Min is the earliest version known to work. Max is the latest, and belongs
// here only when a real incompatibility has been found — not as a guess about
// the future. Neither says which version Chroma prefers, because Chroma does
// not have a preference about a tool that is not its own.
//
// There is no `exact`. Contract 4 had one, and it was the one way this schema
// let somebody write "this machine must run kubectl 1.35.2" — which is Chroma
// deciding the version of a tool that belongs to the user. Removing it is the
// point: a schema should not be able to express what the product will not do,
// or the next person reads the field, sees both readers support it, and quite
// reasonably uses it.
//
// Deliberately not a constraint language. `>=1.2,<2.0 || >=3.0` is a parser, a
// grammar and a class of bug, and nothing here has yet needed one.
type Version struct {
	Min string `json:"min"`
	Max string `json:"max"`
}

// Constrained reports whether this says anything at all.
func (v Version) Constrained() bool {
	return v.Min != "" || v.Max != ""
}

// Tool is something that has to be on PATH. Exactly one of ID or Any is set:
// Any lists names that are interchangeable, as terraform and tofu are.
type Tool struct {
	ID      string   `json:"id"`
	Any     []string `json:"any"`
	Version *Version `json:"version"`
	Reason  string   `json:"reason"`
}

// Names are the names that satisfy this tool, in the order they were declared.
func (t Tool) Names() []string {
	if len(t.Any) > 0 {
		return t.Any
	}
	if t.ID != "" {
		return []string{t.ID}
	}
	return nil
}

// Tools are the three levels a component can ask for. Required means the
// component cannot work without it; the others are degrees of "better with".
type Tools struct {
	Required    []Tool `json:"required"`
	Recommended []Tool `json:"recommended"`
	Optional    []Tool `json:"optional"`
}

// Nvim is what the configuration loads for this component: the language servers
// it enables, the Mason packages it needs, the linters it registers, the
// treesitter parsers it installs, the formatters it hands to conform, the
// schemas it maps onto files, the plugins it brings and the modules it sets up.
// The CLI does not act on any of it — this is the editor's half of the
// contract, and it is here so that both halves are one document.
//
// Schemas are logical names, not URLs and not file globs: "kubernetes", never
// the yannh URL and the four patterns it applies to. Which document those name
// and where it belongs is the editor's business, and putting it here would move
// one language server's implementation details into a product contract that a
// web page or a different editor is also supposed to be able to read.
type Nvim struct {
	Servers    []string `json:"servers"`
	Mason      []string `json:"mason"`
	Linters    []string `json:"linters"`
	Parsers    []string `json:"parsers"`
	Formatters []string `json:"formatters"`
	Schemas    []string `json:"schemas"`
	Plugins    []string `json:"plugins"`
	Modules    []string `json:"modules"`
}

// Component is one file in components/.
type Component struct {
	Contract    int      `json:"contract"`
	ID          string   `json:"id"`
	Name        string   `json:"name"`
	Description string   `json:"description"`
	Requires    []string `json:"requires"`
	Tools       Tools    `json:"tools"`
	Nvim        Nvim     `json:"nvim"`
}

// Set is every component in one tree, keyed by id.
type Set map[string]*Component

// Load reads every .json in dir. Problems are returned rather than raised: a
// contract with one bad file still has readable components, and the caller
// decides whether that is enough to go on.
func Load(dir string) (Set, []string, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, nil, fmt.Errorf("reading %s: %w", dir, err)
	}

	set := Set{}
	var problems []string

	// Sorted, so a contract with two problems reports them in the same order
	// every time and a failing build is reproducible.
	names := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() && filepath.Ext(entry.Name()) == ".json" {
			names = append(names, entry.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		component, problem := readOne(filepath.Join(dir, name))
		switch {
		case problem != "":
			problems = append(problems, fmt.Sprintf("%s %s", name, problem))
		case set[component.ID] != nil:
			problems = append(problems, fmt.Sprintf("%s: id %q is already declared elsewhere", name, component.ID))
		default:
			set[component.ID] = component
		}
	}

	return set, problems, nil
}

func readOne(path string) (*Component, string) {
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Sprintf("could not be read: %v", err)
	}

	// Strict. A field this does not know is a field somebody meant to matter:
	// `require` for `requires` parses cleanly and silently leaves a component
	// with no dependencies, which is the worst possible way to be wrong about a
	// contract that decides what gets installed.
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()

	var component Component
	if err := decoder.Decode(&component); err != nil {
		if strings.Contains(err.Error(), "unknown field") {
			return nil, fmt.Sprintf("has an %v", err)
		}
		return nil, "is not valid JSON"
	}

	// Decode reads the *next* value, because a Decoder is built for streams of
	// them. A file holding `{...}{...}` therefore parses as its first object and
	// the rest is never seen — a component file quietly half-read. Lua's decoder
	// refuses the same input with "Expected the end", so requiring it here is
	// also what keeps the two readers answering alike.
	//
	// Asked for by decoding again and requiring io.EOF, rather than with More().
	// More() is documented as reporting "whether there is another element in the
	// current array or object being parsed", which is not a promise about the end
	// of a top-level stream; it answers correctly today, and this contract is too
	// strict a thing to rest on behaviour the standard library does not describe.
	var extra json.RawMessage
	switch err := decoder.Decode(&extra); {
	case errors.Is(err, io.EOF):
		// The only good case: one document, and then the end of it.
	case err == nil:
		return nil, "has more than one document in it"
	default:
		return nil, "has trailing content after the document"
	}

	if component.ID == "" {
		return nil, "has no id"
	}

	if component.Contract != Contract {
		return nil, fmt.Sprintf("declares contract %d; this CLI understands %d", component.Contract, Contract)
	}

	if problem := validateTools(component.Tools); problem != "" {
		return nil, problem
	}

	if problem := validateNames(component); problem != "" {
		return nil, problem
	}

	return &component, ""
}

// validateNames refuses an empty name anywhere a name is expected. Decoding
// into typed slices gets the shape right for free — that is the half Lua has to
// write out — but `""` is a perfectly good string, and it would arrive as a
// dependency on nothing, a server nobody can enable or a plugin no lockfile
// pins. The Lua reader refuses these, so this is also what keeps the corpus
// agreeing.
func validateNames(c Component) string {
	for _, id := range c.Requires {
		if id == "" {
			return "requires holds an empty name"
		}
	}

	// A slice rather than a map: two problems in one file should be reported in
	// the same order every time.
	lists := []struct {
		kind  string
		names []string
	}{
		{"servers", c.Nvim.Servers},
		{"mason", c.Nvim.Mason},
		{"linters", c.Nvim.Linters},
		{"parsers", c.Nvim.Parsers},
		{"formatters", c.Nvim.Formatters},
		{"schemas", c.Nvim.Schemas},
		{"plugins", c.Nvim.Plugins},
		{"modules", c.Nvim.Modules},
	}

	for _, list := range lists {
		for _, name := range list.names {
			if name == "" {
				return fmt.Sprintf("nvim.%s holds an empty name", list.kind)
			}
		}
	}

	return ""
}

func validateTools(tools Tools) string {
	levels := []struct {
		name  string
		tools []Tool
	}{
		{"required", tools.Required},
		{"recommended", tools.Recommended},
		{"optional", tools.Optional},
	}

	for _, level := range levels {
		for _, tool := range level.tools {
			// Exactly one, not "at least one": with both set the reader picks a
			// winner and drops the other, and nobody writing the file finds out.
			switch {
			case tool.ID != "" && len(tool.Any) > 0:
				return fmt.Sprintf("has a %s tool with both id and any", level.name)
			case tool.ID == "" && len(tool.Any) == 0:
				return fmt.Sprintf("has a %s tool with neither id nor any", level.name)
			case tool.Reason == "":
				return fmt.Sprintf("has a %s tool with no reason", level.name)
			}
			for _, name := range tool.Any {
				if name == "" {
					return fmt.Sprintf("has a %s tool with an empty name in any", level.name)
				}
			}
			if problem := validateVersion(tool.Version); problem != "" {
				return fmt.Sprintf("has a %s tool whose version %s", level.name, problem)
			}
		}
	}

	return ""
}

func validateVersion(v *Version) string {
	if v == nil {
		return ""
	}

	if !v.Constrained() {
		return "says nothing"
	}

	for name, value := range map[string]string{"min": v.Min, "max": v.Max} {
		if value == "" {
			continue
		}
		if !looksLikeVersion(value) {
			return fmt.Sprintf("has a %s that is not a version: %q", name, value)
		}
	}

	if v.Min != "" && v.Max != "" && CompareVersions(v.Min, v.Max) > 0 {
		return fmt.Sprintf("has min %s above max %s", v.Min, v.Max)
	}

	return ""
}

// looksLikeVersion accepts a leading v and dotted numbers, with whatever suffix
// a release likes to carry: 0.26.1, v1.14.3, 2.51.0-rc1.
func looksLikeVersion(value string) bool {
	value = strings.TrimPrefix(value, "v")
	if value == "" {
		return false
	}

	for _, part := range strings.Split(strings.FieldsFunc(value, func(r rune) bool {
		return r == '-' || r == '+'
	})[0], ".") {
		if part == "" {
			return false
		}
		for _, r := range part {
			if r < '0' || r > '9' {
				return false
			}
		}
	}
	return true
}

// CompareVersions orders two dotted versions: -1, 0 or 1. Missing components
// count as zero, so 1.2 and 1.2.0 are the same version. Anything after the
// numbers — a release candidate, a build tag — is ignored, because a constraint
// this project writes is about the numbers.
func CompareVersions(a, b string) int {
	left, right := versionParts(a), versionParts(b)
	for i := 0; i < len(left) || i < len(right); i++ {
		var l, r int
		if i < len(left) {
			l = left[i]
		}
		if i < len(right) {
			r = right[i]
		}
		switch {
		case l < r:
			return -1
		case l > r:
			return 1
		}
	}
	return 0
}

func versionParts(value string) []int {
	value = strings.TrimPrefix(strings.TrimSpace(value), "v")
	value = strings.FieldsFunc(value, func(r rune) bool { return r == '-' || r == '+' })[0]

	var parts []int
	for _, part := range strings.Split(value, ".") {
		number := 0
		for _, r := range part {
			if r < '0' || r > '9' {
				break
			}
			number = number*10 + int(r-'0')
		}
		parts = append(parts, number)
	}
	return parts
}

// Satisfies reports whether a version string meets this constraint. An empty
// constraint is met by anything, including a version nobody could read.
func (v *Version) Satisfies(found string) bool {
	if v == nil || !v.Constrained() {
		return true
	}
	if found == "" {
		return false
	}

	if v.Min != "" && CompareVersions(found, v.Min) < 0 {
		return false
	}
	if v.Max != "" && CompareVersions(found, v.Max) > 0 {
		return false
	}
	return true
}

// ResolveProblems reports dependencies that are not declared, and cycles. A
// cycle is the one an installer cannot survive: a plan built from it has no
// first step, and every dependency in it exists, so nothing else notices.
func (s Set) ResolveProblems() []string {
	var problems []string

	ids := s.IDs()

	for _, id := range ids {
		for _, needed := range s[id].Requires {
			if s[needed] == nil {
				problems = append(problems, fmt.Sprintf("%s requires %q, which is not declared", id, needed))
			}
		}
	}

	// Depth-first, colouring as it goes: grey means "on the current path", so
	// meeting grey again is a cycle rather than a diamond.
	const (
		grey  = 1
		black = 2
	)
	colour := map[string]int{}

	var visit func(id string, trail []string)
	visit = func(id string, trail []string) {
		switch colour[id] {
		case black:
			return
		case grey:
			problems = append(problems, "dependency cycle: "+join(trail, " -> "))
			return
		}

		colour[id] = grey
		for _, needed := range s[id].Requires {
			if s[needed] != nil {
				visit(needed, append(trail, needed))
			}
		}
		colour[id] = black
	}

	for _, id := range ids {
		visit(id, []string{id})
	}

	return problems
}

// IDs are every component id, sorted.
func (s Set) IDs() []string {
	ids := make([]string, 0, len(s))
	for id := range s {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	return ids
}

// Missing are the required tools of this component that are not on PATH.
func (c *Component) Missing(lookup func(string) bool) []Tool {
	return c.Unsatisfied(lookup, nil)
}

// Unsatisfied is Missing with versions taken into account: a tool that is
// present but older than the contract asks for is not satisfied, and reporting
// it as ready is the false positive this exists to prevent. `version` may be
// nil, in which case only presence is checked.
func (c *Component) Unsatisfied(lookup func(string) bool, version func(string) string) []Tool {
	var unsatisfied []Tool
	for _, tool := range c.Tools.Required {
		if _, ok := Satisfy(tool, lookup, version); !ok {
			unsatisfied = append(unsatisfied, tool)
		}
	}
	return unsatisfied
}

// Satisfy reports whether a tool is present and within its constraint, and
// which name answered. A tool with alternatives is satisfied by the first name
// that is both present and acceptable — so an old terraform does not mask a
// good tofu.
func Satisfy(tool Tool, lookup func(string) bool, version func(string) string) (string, bool) {
	for _, name := range tool.Names() {
		if !lookup(name) {
			continue
		}
		if tool.Version == nil || !tool.Version.Constrained() || version == nil {
			return name, true
		}
		if tool.Version.Satisfies(version(name)) {
			return name, true
		}
	}
	return "", false
}

func join(parts []string, sep string) string {
	out := ""
	for i, part := range parts {
		if i > 0 {
			out += sep
		}
		out += part
	}
	return out
}
