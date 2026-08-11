package main

import (
	"errors"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/lock"
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

func onPath(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// locked takes the exclusive lock for one installation.
//
// Every command that moves a directory or rewrites the record takes it;
// `doctor` does not, because it reads. Refused rather than queued: a CLI that
// blocks is indistinguishable from a CLI that has hung, and the useful thing to
// say is that something else is running.
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
// interrupted between moving a directory and writing the record.
//
// After the lock, so two processes cannot recover at once, and before the
// command reads anything else — every one of them acts on the record, and an
// interrupted transaction is precisely the state in which the record and the
// filesystem disagree.
//
// The record is not rewritten. It already describes the last committed
// arrangement; what was wrong was the filesystem, and that is what moves.
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
// is in the way and what a real run would do about it first.
//
// Read-only on purpose, and it is the half of recovery a dry run is allowed to
// reach. `--dry-run` means no change to the state of this machine — not "skip
// the main operation". Measured before this existed: `chroma update --dry-run`
// on an interrupted topology moved two directories and rewrote the
// installation, and reported an interrupted rollback as something it had
// already put back.
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
