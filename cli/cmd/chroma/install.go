package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// cmdInstall builds the plan and prints it. It stops there: `--dry-run` is the
// only form that exists, and the alternative — running a plan nobody has
// implemented the second half of — is not something to approximate.
func cmdInstall(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("install", flag.ContinueOnError)
	dryRun := set.Bool("dry-run", false, "print the plan and stop")
	components := set.String("components", "core", "comma-separated component ids")
	sourceTree := set.String("source-tree", "", "install from a checkout instead of a release (developer-only)")

	dir, root, code := treeWithRoot(set, args, errOut)
	if code != exitOK {
		return code
	}

	// A source tree replaces --tree rather than adding to it: the thing being
	// installed and the thing being read have to be one directory, or the plan
	// describes a contract that is not the one that would be placed.
	if *sourceTree != "" {
		prepared, code := prepareSource(*sourceTree, errOut)
		if code != exitOK {
			return code
		}
		dir = filepath.Join(prepared.Root, "components")
		root = prepared.Root
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

// prepareSource validates a developer checkout and reports where it is.
//
// Both refusals happen before anything is planned, let alone written: a tree
// that is not a Chroma tree, and a tree that is the place it would be installed
// into. The second is not a hypothetical — on the machine this was written on,
// the checkout is the configuration directory, by symlink.
func prepareSource(root string, errOut *os.File) (install.PreparedSource, int) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		fmt.Fprintf(errOut, "--source-tree %s: %v\n", root, err)
		return install.PreparedSource{}, exitMisuse
	}

	prepared, err := install.LocalSource{Root: absolute}.Prepare(context.Background())
	if err != nil {
		fmt.Fprintln(errOut, err)
		return install.PreparedSource{}, exitMisuse
	}

	// Resolved with the isolated layout, which is what --source-tree is for.
	// --default is a production choice and does not belong on this path.
	paths, err := install.ResolvePaths(false)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return install.PreparedSource{}, exitFailed
	}
	if err := install.RefuseSourceInsideTarget(prepared.Root, paths); err != nil {
		fmt.Fprintln(errOut, err)
		return install.PreparedSource{}, exitMisuse
	}

	return prepared, exitOK
}
