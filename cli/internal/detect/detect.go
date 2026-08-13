// Package detect reports what is on this machine. It reports: it does not
// install, and does not know how. What used to live beside this — a table of
// package names per distribution — was deleted rather than left unused, because
// the useful half was always the sentence "kubectl is not here".
//
// Two questions, kept apart: what the system is, and what state each tool the
// enabled components ask for is in. The boundary in the second matters more than
// the states — a tool `core` asks for is something Chroma cannot run without,
// and any other is the user's own and never a reason to refuse an installation.
package detect

import (
	"os"
	"os/exec"
	"runtime"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/toolver"
)

// System is the machine an installation would land on. Kept for the diagnostic
// line `doctor` prints; nothing here decides anything.
type System struct {
	OS   string
	Arch string

	// IsRoot is worth saying out loud in a report, because an installation run
	// as root writes files somebody will later fail to edit.
	IsRoot bool
}

// DetectSystem asks the machine about itself.
func DetectSystem() System {
	return System{
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
		IsRoot: os.Geteuid() == 0,
	}
}

// Status is what is known about a tool.
type Status string

const (
	// Present and new enough.
	Present Status = "present"

	// TooOld is present but older than the contract accepts. Reported apart
	// from absent because telling somebody to install a thing they already have
	// sends them looking for a package they will find installed.
	TooOld Status = "too old"

	// Absent is not there. For an external tool that is a fact, not a fault.
	Absent Status = "absent"
)

// Tool is one requirement, and what is known about it.
type Tool struct {
	// Names are the names that satisfy it — `terraform` or `tofu`, `cc` or
	// `gcc` or `clang`.
	Names []string

	// Level is required, recommended or optional, as the component said.
	Level string

	// Reason is the component's own sentence about why it needs this.
	Reason string

	// Component is the id that asked for it.
	Component string

	// External marks a tool that belongs to the user rather than to Chroma:
	// terraform, kubectl, helm, ansible, aws, docker. Chroma neither installs
	// nor upgrades these, and their absence never blocks anything. The
	// distinction is the component that asked: `core` is Chroma itself.
	External bool

	// Found is the name that answered, and Version what it said it was. Version
	// is empty when the tool would not say — which is not the same as absent,
	// and is why a constraint cannot be checked against it.
	Found   string
	Version string

	// Want is the constraint, if the contract set one. There are three in the
	// whole contract and each is an upstream's stated requirement; no external
	// tool carries one.
	Want *component.Version

	Status Status
}

// Blocking reports whether this missing tool should stop an installation.
//
// Only Chroma's own required tools do. A missing kubectl means the Kubernetes
// features that shell out to kubectl will say so when used, which is both the
// accurate statement and the moment it matters.
func (t Tool) Blocking() bool {
	return !t.External && t.Level == "required" && t.Status != Present
}

// Blocking reports whether anything in a list of tools stops an installation.
// The list form exists because every caller was writing the loop again — and two
// loops with nothing keeping them the same is how a plan once called a machine
// ready that doctor called broken.
func Blocking(tools []Tool) bool {
	for _, tool := range tools {
		if tool.Blocking() {
			return true
		}
	}
	return false
}

// Lookup answers whether a name is on PATH. A parameter so that tests do not
// depend on the machine running them.
type Lookup func(name string) bool

// Version answers what a name reports itself to be, or "".
type Version func(name string) string

// OnPath is the real lookup.
func OnPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// Tools reports the state of everything the enabled components ask for: one
// entry per requirement, in contract order, so two runs on one machine read the
// same. A tool asked for by two components appears once, under the first.
func Tools(set component.Set, enabled []string, lookup Lookup, version Version) []Tool {
	if lookup == nil {
		lookup = OnPath
	}
	if version == nil {
		version = toolver.Of
	}

	var tools []Tool
	seen := map[string]int{}

	for _, id := range enabled {
		one := set[id]
		if one == nil {
			continue
		}

		for _, level := range []struct {
			name  string
			tools []component.Tool
		}{
			{"required", one.Tools.Required},
			{"recommended", one.Tools.Recommended},
			{"optional", one.Tools.Optional},
		} {
			for _, wanted := range level.tools {
				key := wanted.Names()[0]
				if at, already := seen[key]; already {
					// core wins, whatever order the callers pass. A tool core
					// needs is Chroma's own even when a component named it
					// first, or git would become external — and stop blocking —
					// the moment some component sorted ahead of core and also
					// wanted it.
					if id == "core" {
						tools[at].Component = "core"
						tools[at].External = false
						tools[at].Level = level.name
					}
					continue
				}
				seen[key] = len(tools)

				tools = append(tools, describe(wanted, level.name, id, lookup, version))
			}
		}
	}

	return tools
}

// describe works out what is known about one requirement.
func describe(wanted component.Tool, level, id string, lookup Lookup, version Version) Tool {
	tool := Tool{
		Names:     wanted.Names(),
		Level:     level,
		Reason:    wanted.Reason,
		Component: id,
		External:  id != "core",
		Want:      wanted.Version,
	}

	// Present and acceptable, by the same rule the plan uses: the first name
	// that is both there and new enough answers, so an old terraform does not
	// mask a good tofu.
	if found, ok := component.Satisfy(wanted, lookup, version); ok {
		tool.Found = found
		tool.Version = version(found)
		tool.Status = Present
		return tool
	}

	// Present but not acceptable. Worth its own state: a version constraint
	// that fails is not solved by installing the package again.
	for _, name := range tool.Names {
		if lookup(name) {
			tool.Found = name
			tool.Version = version(name)
			tool.Status = TooOld
			return tool
		}
	}

	tool.Status = Absent
	return tool
}

// Split separates Chroma's own tooling from the user's, which is the division
// every caller here needs and none should re-derive.
func Split(tools []Tool) (own, external []Tool) {
	for _, tool := range tools {
		if tool.External {
			external = append(external, tool)
		} else {
			own = append(own, tool)
		}
	}
	return own, external
}

// Printing any of this is `report.External`, deliberately not here: a package
// that both measures and draws is one where changing the drawing can change the
// measurement.
