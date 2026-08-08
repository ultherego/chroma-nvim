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
	case "install", "update", "uninstall", "rollback":
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
  version      this CLI, and the contract it understands

  install, update, uninstall, rollback   not implemented yet

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
	root := set.String("tree", ".", "configuration tree to read")
	set.SetOutput(errOut)
	if err := set.Parse(args); err != nil {
		return "", exitMisuse
	}

	dir := filepath.Join(*root, "components")
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "no components directory in %s — is that a Chroma Neovim tree?\n", *root)
		return "", exitMisuse
	}
	return dir, exitOK
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
		fmt.Fprintf(out, "%-12s %-28s %s\n", one.ID, one.Name, requires)
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
			fmt.Fprintf(out, "ok      %-12s %s\n", one.ID, one.Name)
			continue
		}

		incomplete = true
		fmt.Fprintf(out, "missing %-12s %s\n", one.ID, one.Name)
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
