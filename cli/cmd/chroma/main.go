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
