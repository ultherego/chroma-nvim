// Command chroma installs and maintains Chroma Neovim.
//
// This is the skeleton: the commands that only need to read are here, and the
// ones that write are not written yet. See cli/DESIGN.md for what they will do
// and, more usefully, what they will refuse to do.
//
// One command per file. This file holds the entry point and nothing else,
// because the installer is about to arrive and cmdInstall is where it lands;
// a file that holds every command is a file that ends up holding the installer
// as well.
package main

import (
	"fmt"
	"os"
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
	case "update":
		return cmdUpdate(args[1:], out, errOut)
	case "install":
		return cmdInstall(args[1:], out, errOut)
	case "package":
		return cmdPackage(args[1:], out, errOut)
	case "uninstall", "rollback":
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

  components   change which components an installation enables (--tree lists a tree)
  doctor       report what each component needs and what is missing
  install      install a release, or a checkout with --source-tree
  update       replace a managed installation with another release
  version      this CLI, and the contract it understands

  package      build a release archive and its checksums (developer-only)

  uninstall, rollback   not implemented yet

Both reading commands take --tree to point at a configuration; the default is
the directory this is run from.
`)
}
