// Package plan turns a request into something a person can check before
// anything happens.
//
// Nothing here touches a disk. A plan is built, printed, and only then acted
// on — so `--dry-run` is the same code path as an install, minus the last step.
package plan

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
)

// Detector describes the tools a set of components needs, as they are on this
// machine. `detect.Tools` is the only implementation; it is a parameter so a
// plan can be built for a machine other than this one, which is what makes it
// testable.
//
// It is called with the components the plan resolved, not with the ones that
// were asked for: a component pulled in by `requires` needs its tools described
// too, and a list made before the resolution would not have them.
type Detector func(component.Set, []string) []detect.Tool

// Tool is one entry in the plan's tool list, and it is `detect.Tool` because
// there is one answer to "is this tool usable on this machine" and it lives
// there.
//
// It used to be a type of its own, filled in from a `func(string) bool` that
// asked only whether the name was on PATH. So a plan called a git of 2.18
// present while `doctor`, reading the same executable, called it too old for
// the floor core states — and the installation went ahead against a machine
// that could not run it. Measured, with a stubbed PATH: the plan was complete
// and doctor exited 4 on the same machine, at the same moment.
//
// Two definitions of "present" is the shape of that bug, so there is now one.
type Tool = detect.Tool

// Plan is what would happen. Component ids are sorted, so the same request
// produces the same plan and two runs can be compared.
type Plan struct {
	// Requested is what the user asked for, as given.
	Requested []string
	// Components is what will be enabled, including what was pulled in.
	Components []string
	// Added is the difference: dependencies nobody asked for by name.
	Added []string
	// Tools are the required and recommended tools of the chosen components.
	Tools []Tool
	// Unknown are requested ids that no component declares.
	Unknown []string
}

// Complete reports whether everything Chroma itself needs is present.
//
// External tools are deliberately not counted. Choosing the kubernetes
// component means "give me Chroma's Kubernetes features", not "install
// kubectl" — so an absent kubectl is a fact about the machine, not an
// incomplete plan, and the features that shell out to it say so when used.
// Without git, by contrast, there are no plugins and there is no installation.
func (p Plan) Complete() bool {
	for _, tool := range p.Tools {
		// Present, not merely found. A required tool below the floor its
		// component states is exactly as unusable as an absent one, and this is
		// the only place that decides whether an installation may proceed.
		//
		// Only required, and only Chroma's own: a recommended tool that is too
		// old is a fact about the machine, reported and not in the way.
		if !tool.External && tool.Level == "required" && tool.Status != detect.Present {
			return false
		}
	}
	return true
}

// External returns the user's own tools, in plan order. This is a report, not
// a check: the caller prints it and carries on.
func (p Plan) External() []Tool {
	var out []Tool
	for _, tool := range p.Tools {
		if tool.External {
			out = append(out, tool)
		}
	}
	return out
}

// Build expands the request through the dependency graph and reports what that
// costs. An unknown id is reported rather than ignored: silently installing
// less than was asked for is how a user ends up debugging a component that was
// never enabled.
// Build works out what would be enabled and what it needs.
//
// The tools are described by the detector rather than worked out here from a
// name lookup. See Tool and Detector.
func Build(set component.Set, requested []string, describe Detector) Plan {
	plan := Plan{Requested: append([]string(nil), requested...)}

	chosen := map[string]bool{}
	asked := map[string]bool{}

	var add func(id string)
	add = func(id string) {
		if chosen[id] {
			return
		}
		chosen[id] = true
		for _, needed := range set[id].Requires {
			if set[needed] != nil {
				add(needed)
			}
		}
	}

	for _, id := range requested {
		if set[id] == nil {
			plan.Unknown = append(plan.Unknown, id)
			continue
		}
		asked[id] = true
		add(id)
	}

	for id := range chosen {
		plan.Components = append(plan.Components, id)
		if !asked[id] {
			plan.Added = append(plan.Added, id)
		}
	}
	sort.Strings(plan.Components)
	sort.Strings(plan.Added)
	sort.Strings(plan.Unknown)

	// One entry per tool, not per component that wants it: the same tool asked
	// for twice is one thing to install, and saying so twice reads like two.
	// Described now, with the resolved list, and keyed the way the loop below
	// keys them so a tool named by two components is one entry in both.
	described := map[string]detect.Tool{}
	for _, tool := range describe(set, plan.Components) {
		described[strings.Join(tool.Names, "|")] = tool
	}

	seen := map[string]int{}
	for _, id := range plan.Components {
		for _, level := range []struct {
			name  string
			tools []component.Tool
		}{
			{"required", set[id].Tools.Required},
			{"recommended", set[id].Tools.Recommended},
		} {
			for _, tool := range level.tools {
				key := strings.Join(tool.Names(), "|")
				if at, already := seen[key]; already {
					// Required wins: a tool one component merely recommends and
					// another cannot work without is required.
					if level.name == "required" {
						plan.Tools[at].Level = "required"
					}
					// And core wins: a tool core asks for is Chroma's own even
					// if a component named it first. Set by first writer, this
					// would make git external whenever some component happened
					// to sort ahead of core and want it too.
					if id == "core" {
						plan.Tools[at].Component = "core"
						plan.Tools[at].External = false
					}
					continue
				}

				seen[key] = len(plan.Tools)
				plan.Tools = append(plan.Tools, described[key])
			}
		}
	}

	return plan
}

// Render writes the plan in the shape cli/DESIGN.md shows: what will be
// enabled, what that added, and which tools are missing.
func (p Plan) Render(w io.Writer) {
	if len(p.Unknown) > 0 {
		fmt.Fprintf(w, "Unknown components: %s\n\n", strings.Join(p.Unknown, ", "))
	}

	if len(p.Components) == 0 {
		// Saying "nothing is missing" about a plan that would install nothing is
		// technically true and completely misleading.
		fmt.Fprint(w, "  Components    none — nothing would be installed\n")
		return
	}

	fmt.Fprintf(w, "  Components    %s\n", strings.Join(p.Components, ", "))
	if len(p.Added) > 0 {
		fmt.Fprintf(w, "                %s pulled in as a dependency\n", strings.Join(p.Added, ", "))
	}

	// Chroma's own tooling: the half of this that can stop an installation.
	var missing, present []string
	for _, tool := range p.Tools {
		if tool.External {
			continue
		}
		name := strings.Join(tool.Names, " or ")
		if tool.Status == detect.Present {
			present = append(present, name)
		} else {
			missing = append(missing, fmt.Sprintf("%s (%s)", name, tool.Level))
		}
	}

	if len(present) > 0 {
		fmt.Fprintf(w, "  Present       %s\n", strings.Join(present, ", "))
	}
	switch {
	case len(missing) > 0:
		fmt.Fprintf(w, "  Missing       %s\n", strings.Join(missing, ", "))
	case len(p.Components) > 0:
		fmt.Fprint(w, "  Missing       nothing\n")
	}

	// The user's own tools, named but not counted. Listing them here would read
	// as a checklist to satisfy before installing, which is exactly what they
	// are not — so this says how many and where the full report is.
	if absent := p.absentExternal(); len(absent) > 0 {
		fmt.Fprintf(w, "  External      %s not on PATH; Chroma does not install these,\n", strings.Join(absent, ", "))
		fmt.Fprint(w, "                and installing without them changes nothing here\n")
	}
}

// absentExternal names the user's own tools that are not on PATH.
func (p Plan) absentExternal() []string {
	var out []string
	for _, tool := range p.External() {
		if tool.Status != detect.Present {
			out = append(out, strings.Join(tool.Names, "/"))
		}
	}
	return out
}
