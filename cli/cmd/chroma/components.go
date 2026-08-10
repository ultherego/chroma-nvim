package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
	"github.com/ultherego/chroma-nvim/cli/internal/tui"
)

// cmdComponents changes which parts of an installation are enabled.
//
// Two commands in one, told apart by whether a tree is named. `--tree` asks a
// question about a configuration directory and answers it — the developer's
// listing. Everything else acts on the installation this machine has.
//
// It does not make a generation. A generation is a release of Chroma; which
// parts of it somebody wants is a different fact with a different lifetime, so
// `install.json` is not touched, nothing is backed up, and a rollback later
// will move the version without moving this.
func cmdComponents(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("components", flag.ContinueOnError)
	set.SetOutput(errOut)

	tree := set.String("tree", "", "list the components a configuration tree offers, and change nothing")
	assumeYes := set.Bool("yes", false, "apply the change without asking")
	nonInteractive := set.Bool("non-interactive", false, "never ask; --set is then required")

	// --set is the primitive, and it is a target state rather than a mutation:
	// what the installation should have afterwards, in full. `--set ''` is core
	// alone, said out loud, the same as it means to `install`.
	var wanted []string
	given := false
	set.Func("set", "the components to have afterwards, comma-separated; empty means core alone", func(value string) error {
		given = true
		wanted = []string{}
		for _, id := range strings.Split(value, ",") {
			if trimmed := strings.TrimSpace(id); trimmed != "" {
				wanted = append(wanted, trimmed)
			}
		}
		return nil
	})

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	if *tree != "" {
		return listComponents(*tree, out, errOut)
	}

	if *nonInteractive && !given {
		fmt.Fprint(errOut, "--non-interactive needs --set: there is nothing to fall back on.\n")
		return exitMisuse
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	paths, current, code := managed(errOut)
	if code != exitOK {
		return code
	}

	held, code := locked(errOut)
	if code != exitOK {
		return code
	}
	defer held.Release()

	if code := recovered(paths, current, out, errOut); code != exitOK {
		return code
	}

	// The contract of the release that is installed, not of some tree on this
	// machine. A component only exists if what is on disk can run it.
	loaded, code := load(filepath.Join(current.ConfigDir, "components"), errOut)
	if code != exitOK {
		return code
	}

	existing, code := carriedOver(paths, loaded, errOut)
	if code != exitOK {
		return code
	}

	if !given {
		chosen, err := tui.Components(loaded, existing, os.Stdin, out)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return exitMisuse
		}
		wanted = chosen
	}

	if code := legal(wanted, loaded, current.ConfigDir, errOut); code != exitOK {
		return code
	}

	added, removed := difference(existing, wanted)
	if len(added) == 0 && len(removed) == 0 {
		fmt.Fprint(out, "Components are already configured.\n")
		return exitOK
	}

	// The same resolver the installation uses, so `requires` means one thing.
	built := plan.Build(loaded, append([]string{"core"}, wanted...), onPath)

	fmt.Fprint(out, "\nChanges\n\n")
	for _, id := range added {
		fmt.Fprintf(out, "  + %s\n", name(loaded, id))
	}
	for _, id := range removed {
		fmt.Fprintf(out, "  - %s\n", name(loaded, id))
	}
	fmt.Fprint(out, "\n")
	built.Render(out)

	if !built.Complete() {
		fmt.Fprint(errOut, "\nSomething Chroma itself needs is missing. Install it and try again.\n")
		return exitPreflight
	}

	if !*assumeYes && !*nonInteractive {
		if !asked(out, "\nApply? [y/N] ") {
			fmt.Fprint(out, "Nothing was changed.\n")
			return exitDeclined
		}
	}

	installer := &install.Installer{
		Runner: install.ExecRunner{Log: logFile(paths, errOut)},
		Sink:   lineSink{out: out},
	}

	result, err := installer.Reconfigure(ctx, paths, loaded, wanted)
	if err != nil {
		fmt.Fprintln(errOut, err)
		fmt.Fprint(errOut, "The selection you had is still the one in force.\n")
		return exitFailed
	}

	fmt.Fprintf(out, "\nComponents are now: %s\n", strings.Join(result.Enabled, ", "))
	fmt.Fprintf(out, "The installation is still %s; changing components does not change the release.\n", current.Version)

	_, external := detect.Split(detect.Tools(loaded, result.Enabled, nil, nil))
	detect.RenderExternal(out, external)

	return exitOK
}

// listComponents answers "what does this tree offer", and changes nothing.
func listComponents(tree string, out, errOut *os.File) int {
	set, code := load(tree, errOut)
	if code != exitOK {
		return code
	}

	for _, id := range set.IDs() {
		one := set[id]
		requires := ""
		if len(one.Requires) > 0 {
			requires = "requires " + strings.Join(one.Requires, ", ")
		}
		fmt.Fprintf(out, "%-16s %-24s %s\n", one.ID, one.Name, requires)
	}
	return exitOK
}

// legal checks a requested selection against the contract that is installed.
//
// The same rules the selection document itself keeps, checked here so that a
// refusal happens before the editor is asked to do anything.
func legal(wanted []string, set component.Set, configDir string, errOut *os.File) int {
	seen := map[string]bool{}
	for _, id := range wanted {
		switch {
		case id == "core":
			fmt.Fprintf(errOut, "%q is always installed and is not a choice.\n", id)
			return exitMisuse
		case seen[id]:
			fmt.Fprintf(errOut, "%q is named twice.\n", id)
			return exitMisuse
		case set[id] == nil:
			fmt.Fprintf(errOut, "This installation has no component %q.\nRun `chroma components --tree %s` to see what it has.\n", id, configDir)
			return exitMisuse
		}
		seen[id] = true
	}
	return exitOK
}

// difference says what a change adds and what it takes away.
func difference(before, after []string) (added, removed []string) {
	had := map[string]bool{}
	for _, id := range before {
		had[id] = true
	}
	wants := map[string]bool{}
	for _, id := range after {
		wants[id] = true
	}

	for id := range wants {
		if !had[id] {
			added = append(added, id)
		}
	}
	for id := range had {
		if !wants[id] {
			removed = append(removed, id)
		}
	}

	sort.Strings(added)
	sort.Strings(removed)
	return added, removed
}

func name(set component.Set, id string) string {
	if one := set[id]; one != nil && one.Name != "" {
		return one.Name
	}
	return id
}
