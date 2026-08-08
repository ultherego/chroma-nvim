// Package component reads the contract in components/ — the one interface the
// Lua configuration and this CLI share.
//
// The rules here must match lua/chroma/components.lua. Where they disagree, one
// side accepts a contract the other rejects, and the disagreement surfaces
// during an install rather than in a test. That is why the shipped contract is
// checked by both.
package component

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
)

// Contract is the version this CLI understands. A component declaring a higher
// one was written for a newer Chroma; reading it anyway is how the two sides
// drift apart quietly. See cli/DESIGN.md, "The component contract".
const Contract = 1

// Tool is something that has to be on PATH. Exactly one of ID or Any is set:
// Any lists names that are interchangeable, as terraform and tofu are.
type Tool struct {
	ID     string   `json:"id"`
	Any    []string `json:"any"`
	Reason string   `json:"reason"`
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

// Nvim is what the configuration loads for this component.
type Nvim struct {
	Modules []string `json:"modules"`
	Plugins []string `json:"plugins"`
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

	var component Component
	if err := json.Unmarshal(contents, &component); err != nil {
		return nil, "is not valid JSON"
	}

	if component.ID == "" {
		return nil, "has no id"
	}

	if component.Contract != Contract {
		return nil, fmt.Sprintf("declares contract %d; this CLI understands %d", component.Contract, Contract)
	}

	return &component, ""
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
	var missing []Tool
	for _, tool := range c.Tools.Required {
		if !satisfied(tool, lookup) {
			missing = append(missing, tool)
		}
	}
	return missing
}

func satisfied(tool Tool, lookup func(string) bool) bool {
	for _, name := range tool.Names() {
		if lookup(name) {
			return true
		}
	}
	return false
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
