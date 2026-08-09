package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// cmdInstall builds the plan and prints it. It stops there: `--dry-run` is the
// only form that exists, and the alternative — running a plan nobody has
// implemented the second half of — is not something to approximate.
func cmdInstall(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("install", flag.ContinueOnError)
	dryRun := set.Bool("dry-run", false, "print the plan and stop")
	components := set.String("components", "core", "comma-separated component ids")

	dir, root, code := treeWithRoot(set, args, errOut)
	if code != exitOK {
		return code
	}

	if !*dryRun {
		fmt.Fprint(errOut, "install is not implemented yet; --dry-run builds and prints the plan.\nSee cli/DESIGN.md for what the rest of it will do.\n")
		return exitMisuse
	}

	loaded, code := load(dir, errOut)
	if code != exitOK {
		return code
	}

	requested := strings.Split(*components, ",")
	for i := range requested {
		requested[i] = strings.TrimSpace(requested[i])
	}

	built := plan.Build(loaded, requested, onPath)

	fmt.Fprintf(out, "Chroma Neovim would be installed from %s.\n\n", root)
	built.Render(out)
	fmt.Fprint(out, "\nNothing was written: this is a dry run.\n")

	// An unknown component is a request that cannot be satisfied, whatever the
	// rest of the plan says.
	if len(built.Unknown) > 0 {
		return exitMisuse
	}
	if !built.Complete() {
		return exitPreflight
	}
	return exitOK
}
