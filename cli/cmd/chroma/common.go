package main

import (
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
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
