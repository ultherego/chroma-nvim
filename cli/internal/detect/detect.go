// Package detect reports what is on this machine.
//
// Two questions, kept apart. What the system is — its package manager, whether
// this is running as root — and what state each tool the enabled components ask
// for is in. The second is the one a person reads before deciding whether to
// install anything, and "missing" was never enough of an answer: a tool that is
// absent but installable, one that is absent and has to be fetched by hand, and
// one that is present but older than the contract accepts are three different
// problems with three different next steps.
package detect

import (
	"os"
	"os/exec"
	"runtime"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/pkg"
	"github.com/ultherego/chroma-nvim/cli/internal/toolver"
)

// System is the machine an installation would land on.
type System struct {
	OS   string
	Arch string

	// PackageManager is the first of pkg.Managers found on PATH, or empty.
	// First-found rather than best-guess: a machine with two of them is not one
	// to be clever about, and the CLI says which it chose.
	PackageManager string

	// IsRoot matters because the install commands carry `sudo`, which is
	// neither present nor needed when already root.
	IsRoot bool
}

// DetectSystem asks the machine about itself.
func DetectSystem() System {
	system := System{
		OS:     runtime.GOOS,
		Arch:   runtime.GOARCH,
		IsRoot: os.Geteuid() == 0,
	}

	for _, manager := range pkg.Managers {
		if _, err := exec.LookPath(manager); err == nil {
			system.PackageManager = manager
			break
		}
	}

	return system
}

// Status is what has to happen about a tool, if anything.
type Status string

const (
	// Present and new enough. Nothing to do.
	Present Status = "present"

	// TooOld is present but older than the contract accepts. Reported apart
	// from missing because telling somebody to install a thing they already
	// have sends them looking for a package they will find installed.
	TooOld Status = "too old"

	// Installable is absent, and this machine's package manager has a name for
	// it that somebody verified.
	Installable Status = "installable"

	// Manual is absent, and there is no verified way to install it here. The
	// CLI says what is missing and why, and stops there rather than guessing a
	// package name.
	Manual Status = "manual"
)

// Tool is one requirement, and what to do about it.
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

	// Found is the name that answered, and Version what it said it was. Version
	// is empty when the tool would not say — which is not the same as absent,
	// and is why a constraint cannot be checked against it.
	Found   string
	Version string

	// Want is the constraint, if the contract set one.
	Want *component.Version

	Status Status

	// Package and Command are set when Status is Installable: what to install,
	// and the argv that would install it.
	Package string
	Command []string
}

// Required reports whether an installation cannot work without this.
func (t Tool) Required() bool { return t.Level == "required" }

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

// Tools reports the state of everything the enabled components ask for.
//
// One entry per requirement, in contract order, so that two runs on one machine
// read the same. A tool asked for by two components appears once, under the
// first that asked — the point is what has to be done about it, and that is the
// same either way.
func Tools(set component.Set, enabled []string, system System, lookup Lookup, version Version) []Tool {
	if lookup == nil {
		lookup = OnPath
	}
	if version == nil {
		version = toolver.Of
	}

	var tools []Tool
	seen := map[string]bool{}

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
				if seen[key] {
					continue
				}
				seen[key] = true

				tools = append(tools, describe(wanted, level.name, id, system, lookup, version))
			}
		}
	}

	return tools
}

// describe works out the state of one requirement.
func describe(wanted component.Tool, level, id string, system System, lookup Lookup, version Version) Tool {
	tool := Tool{
		Names:     wanted.Names(),
		Level:     level,
		Reason:    wanted.Reason,
		Component: id,
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

	// Absent. Whether that is actionable depends on this machine.
	tool.Status = Manual
	if system.PackageManager == "" {
		return tool
	}

	for _, name := range tool.Names {
		if packaged, known := pkg.Package(system.PackageManager, name); known {
			command, buildable := pkg.InstallCommand(system.PackageManager, []string{packaged})
			if !buildable {
				break
			}
			// Already root: the sudo the command carries is neither needed nor
			// available in every image that runs as root.
			if system.IsRoot && len(command) > 0 && command[0] == "sudo" {
				command = command[1:]
			}
			tool.Status = Installable
			tool.Package = packaged
			tool.Command = command
			break
		}
	}

	return tool
}
