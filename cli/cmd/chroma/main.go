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
	case "-h", "--help", "help":
		usage(out)
		return exitOK
	}

	if command, known := commands[args[0]]; known {
		return command(args[1:], out, errOut)
	}
	if unfinished[args[0]] {
		fmt.Fprintf(errOut, "%s is not implemented yet — see cli/DESIGN.md\n", args[0])
		return exitMisuse
	}

	fmt.Fprintf(errOut, "unknown command %q\n\n", args[0])
	usage(errOut)
	return exitMisuse
}

// commands is the dispatch, as data.
//
// A table rather than a switch so that something can check it. A `rollback`
// that was written, built, vetted and unit-tested still reached nobody, because
// the only thing standing between the command and the user was a `case` nobody
// had added — and no test could see the gap while dispatch was control flow.
var commands = map[string]func(args []string, out, errOut *os.File) int{
	"components": cmdComponents,
	"doctor":     cmdDoctor,
	"install":    cmdInstall,
	"package":    cmdPackage,
	"rollback":   cmdRollback,
	"uninstall":  cmdUninstall,
	"update":     cmdUpdate,
	"version":    func(_ []string, out, _ *os.File) int { return cmdVersion(out) },
}

// unfinished are named in the usage text and do not exist yet. Listed so that
// "not implemented" is a deliberate answer rather than a missing case.
var unfinished = map[string]bool{}

func usage(w *os.File) {
	fmt.Fprint(w, `chroma — install and maintain Chroma Neovim

  components   change which components an installation enables (--tree lists a tree)
  doctor       report what each component needs and what is missing
  install      install a release, or a checkout with --source-tree
  update       replace a managed installation with another release
  rollback     put the previous generation back, keeping your components
  uninstall    remove everything Chroma made, and give back what it borrowed
  version      this CLI, and the contract it understands

  package      build a release archive and its checksums (developer-only)

Both reading commands take --tree to point at a configuration; the default is
the directory this is run from.
`)
}
