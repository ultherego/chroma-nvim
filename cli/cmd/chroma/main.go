// Command chroma installs and maintains Chroma Neovim.
//
// This is the skeleton: the commands that only need to read are here, and the
// ones that write are not written yet. See cli/DESIGN.md for what they will do
// and, more usefully, what they will refuse to do.
package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// Exit codes are part of the interface: this ends up in scripts.
const (
	exitOK        = 0
	exitFailed    = 1
	exitMisuse    = 2
	exitDeclined  = 3
	exitPreflight = 4
)

// version is set at build time with -ldflags. Empty means somebody built this
// by hand, which is worth saying rather than printing a plausible number.
var version = ""

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, out, errOut *os.File) int {
	if len(args) == 0 {
		usage(errOut)
		return exitMisuse
	}

	switch args[0] {
	case "version":
		return cmdVersion(out)
	case "components":
		return cmdComponents(args[1:], out, errOut)
	case "doctor":
		return cmdDoctor(args[1:], out, errOut)
	case "install":
		return cmdInstall(args[1:], out, errOut)
	case "update", "uninstall", "rollback":
		fmt.Fprintf(errOut, "%s is not implemented yet — see cli/DESIGN.md\n", args[0])
		return exitMisuse
	case "-h", "--help", "help":
		usage(out)
		return exitOK
	default:
		fmt.Fprintf(errOut, "unknown command %q\n\n", args[0])
		usage(errOut)
		return exitMisuse
	}
}

func usage(w *os.File) {
	fmt.Fprint(w, `chroma — install and maintain Chroma Neovim

  components   list the components of a configuration tree
  doctor       report what each component needs and what is missing
  install      --dry-run only for now: builds the plan and prints it
  version      this CLI, and the contract it understands

  update, uninstall, rollback   not implemented yet

Both reading commands take --tree to point at a configuration; the default is
the directory this is run from.
`)
}

func cmdVersion(out *os.File) int {
	shown := version
	if shown == "" {
		shown = "(built from source)"
	}
	fmt.Fprintf(out, "chroma %s\ncomponent contract %d\n", shown, component.Contract)
	return exitOK
}

// tree resolves --tree, defaulting to the working directory, and returns the
// components directory inside it.
func tree(set *flag.FlagSet, args []string, errOut *os.File) (string, int) {
	dir, _, code := treeWithRoot(set, args, errOut)
	return dir, code
}

// treeWithRoot returns the components directory and the tree it is in, because
// a message about where something would be installed should name the tree
// rather than the directory this happens to read.
func treeWithRoot(set *flag.FlagSet, args []string, errOut *os.File) (string, string, int) {
	root := set.String("tree", ".", "configuration tree to read")
	set.SetOutput(errOut)
	if err := set.Parse(args); err != nil {
		return "", "", exitMisuse
	}

	dir := filepath.Join(*root, "components")
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "no components directory in %s — is that a Chroma Neovim tree?\n", *root)
		return "", "", exitMisuse
	}
	return dir, *root, exitOK
}

func load(dir string, errOut *os.File) (component.Set, int) {
	set, problems, err := component.Load(dir)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return nil, exitFailed
	}

	// Reported and fatal: a plan built from a contract that does not describe
	// itself is a plan nobody can check.
	for _, problem := range problems {
		fmt.Fprintf(errOut, "contract: %s\n", problem)
	}
	for _, problem := range set.ResolveProblems() {
		fmt.Fprintf(errOut, "contract: %s\n", problem)
		problems = append(problems, problem)
	}
	if len(problems) > 0 {
		return nil, exitFailed
	}

	return set, exitOK
}

func cmdComponents(args []string, out, errOut *os.File) int {
	dir, code := tree(flag.NewFlagSet("components", flag.ContinueOnError), args, errOut)
	if code != exitOK {
		return code
	}

	set, code := load(dir, errOut)
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

func cmdDoctor(args []string, out, errOut *os.File) int {
	dir, code := tree(flag.NewFlagSet("doctor", flag.ContinueOnError), args, errOut)
	if code != exitOK {
		return code
	}

	set, code := load(dir, errOut)
	if code != exitOK {
		return code
	}

	onPath := func(name string) bool {
		_, err := exec.LookPath(name)
		return err == nil
	}

	incomplete := false
	for _, id := range set.IDs() {
		one := set[id]
		missing := one.Missing(onPath)
		if len(missing) == 0 {
			fmt.Fprintf(out, "ok      %-16s %s\n", one.ID, one.Name)
			continue
		}

		incomplete = true
		fmt.Fprintf(out, "missing %-16s %s\n", one.ID, one.Name)
		for _, tool := range missing {
			fmt.Fprintf(out, "          %s — %s\n", strings.Join(tool.Names(), " or "), tool.Reason)
		}
	}

	// Not a failure: a component nobody wants is allowed to be incomplete. The
	// exit code says "something is missing", and the caller decides.
	if incomplete {
		return exitPreflight
	}
	return exitOK
}

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

	onPath := func(name string) bool {
		_, err := exec.LookPath(name)
		return err == nil
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
