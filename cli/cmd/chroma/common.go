package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/lock"
	"github.com/ultherego/chroma-nvim/cli/internal/tui"
)

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

// locked takes the exclusive lock for one installation. Every command that moves
// a directory or rewrites the record takes it; `doctor` does not, because it
// reads. Refused rather than queued: a CLI that blocks is indistinguishable from
// one that has hung.
func locked(errOut *os.File) (*lock.Lock, int) {
	path, err := lock.Path()
	if err != nil {
		fmt.Fprintln(errOut, err)
		return nil, exitFailed
	}

	held, err := lock.Acquire(path)
	switch {
	case errors.Is(err, lock.ErrBusy):
		fmt.Fprintf(errOut, "%v.\nWait for it to finish.\n", err)
		return nil, exitMisuse
	case err != nil:
		fmt.Fprintln(errOut, err)
		return nil, exitFailed
	}
	return held, exitOK
}

// recovered puts back the committed arrangement if a previous run was
// interrupted between moving a directory and writing the record. After the lock,
// so two processes cannot recover at once, and before the command reads anything
// else. The record is not rewritten: it already describes the last committed
// arrangement, and what was wrong was the filesystem.
func recovered(paths install.Paths, current installstate.State, out, errOut *os.File) int {
	why, err := install.Recover(paths, current)
	if err != nil {
		fmt.Fprintln(errOut, err)
		fmt.Fprint(errOut, "Nothing was changed. An earlier Chroma operation did not finish and this cannot tell what to put back.\n")
		return exitFailed
	}
	if why != "" {
		fmt.Fprintf(out, "%s\n\n", why)
	}
	return exitOK
}

// foreseen says, without touching anything, whether an interrupted transaction
// is in the way and what a real run would do about it first. Read-only on
// purpose: `--dry-run` means no change to this machine, not "skip the main
// operation". Measured before this existed — `chroma update --dry-run` on an
// interrupted topology moved two directories and rewrote the installation.
func foreseen(paths install.Paths, current installstate.State, out, errOut *os.File) int {
	found, err := install.DetectInterruption(paths, current)
	if err != nil {
		fmt.Fprintln(errOut, err)
		fmt.Fprint(errOut, "Nothing was changed. An earlier Chroma operation did not finish and this cannot tell what to put back.\n")
		return exitFailed
	}
	if found != nil {
		fmt.Fprintf(out, "An earlier Chroma operation did not finish.\n%s\n\nA real run would put that right before doing anything else.\n\n", found.Why)
	}
	return exitOK
}

// describeTools is how every plan finds out what this machine has: one function,
// passed to plan.Build, and the same detection `doctor` reports from. There used
// to be a second definition, and the two disagreed about the same machine.
func describeTools(set component.Set, enabled []string) []detect.Tool {
	return detect.Tools(set, enabled, nil, nil)
}

// contractIn resolves `--tree <root>` to the directory holding the component
// contract, which is the one place that decides what the flag means. `--tree`
// names a configuration root, and `doctor` read it that way while `components`
// passed the root straight to the loader — so the same flag on the same checkout
// silently listed nothing for one of them, exit 0 and all.
func contractIn(root string, errOut *os.File) (string, int) {
	dir := filepath.Join(root, "components")
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "no components directory in %s — is that a Chroma Neovim tree?\n", root)
		return "", exitMisuse
	}
	return dir, exitOK
}

// The two questions this CLI asks a person, held in package variables: a test
// about the installer should not be a test about a terminal emulator. One of
// them answers "take over ~/.config/nvim" and then proves the lock followed the
// answer rather than the paths resolved before it. Replaced with t.Cleanup, and
// never from a parallel test.
var (
	askInteractively           = tui.Ask
	askComponentsInteractively = tui.Components
)

// refused turns a question that got no usable answer into an exit code. Two
// different things arrive here and they used to leave as one: escape is a person
// deciding against an installation, a closed pipe is a machine that was never
// able to answer. Both exited 2, so pressing escape was reported as misuse —
// while answering `Proceed? [y/N]` with `n` exited 3 and said "Nothing was
// changed."
//
// Escape now gets that same 3 and that same sentence. A closed pipe keeps 2 and
// keeps naming the flags that would have let it answer.
func refused(err error, out, errOut *os.File) int {
	if errors.Is(err, tui.ErrAborted) {
		fmt.Fprint(out, "Nothing was changed.\n")
		return exitDeclined
	}

	fmt.Fprintln(errOut, err)
	return exitMisuse
}
