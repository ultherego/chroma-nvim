package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/release"
)

// cmdPackage builds the artefacts a release is made of. Developer-only, and in
// the same binary rather than a script for one reason: the release workflow has
// to build the archive with the code that was tested. What goes in comes from
// install.RuntimeEntries, so a release and a development install are the same
// files.
func cmdPackage(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("package", flag.ContinueOnError)
	set.SetOutput(errOut)

	tree := set.String("tree", ".", "the configuration tree to package")
	version := set.String("version", "", "the version this release is, e.g. v1.0.0")
	outDir := set.String("out", "dist", "where to write the archive and SHA256SUMS")
	allowDirty := set.Bool("allow-dirty", false, "package a tree with uncommitted runtime changes; the result belongs to no commit")

	// Files built elsewhere that the release publishes beside the archive —
	// the cross-compiled binaries. They are listed in SHA256SUMS by this
	// command rather than by the workflow, so one file describes every asset
	// and it is written by the code that has tests.
	var assets multiFlag
	set.Var(&assets, "asset", "another file to list in SHA256SUMS; repeatable")

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	if *version == "" {
		fmt.Fprint(errOut, "--version is required: a release archive is named after the release it is.\n")
		return exitMisuse
	}

	root, err := filepath.Abs(*tree)
	if err != nil {
		fmt.Fprintf(errOut, "--tree %s: %v\n", *tree, err)
		return exitMisuse
	}

	// The same reader the installer uses, so a tree that cannot be installed is
	// not packaged into a release that will fail on somebody else's machine.
	if _, code := load(filepath.Join(root, "components"), errOut); code != exitOK {
		return code
	}

	// A release says "built from commit X" and a tag points at X. Both are
	// false if the runtime files differ from what X holds — which is not
	// hypothetical: the first artefacts built here carried a lazy-lock.json a
	// `:Lazy sync` had changed and nobody had committed, so the archive
	// described no commit at all and its checksum was reproducible only by
	// accident of one working tree.
	attribution, err := release.Attribute(root)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}
	if len(attribution.Dirty) > 0 && !*allowDirty {
		fmt.Fprintf(errOut, "%s has uncommitted changes to files that go into the archive:\n", root)
		for _, entry := range attribution.Dirty {
			fmt.Fprintf(errOut, "  %s\n", entry)
		}
		fmt.Fprint(errOut, "\nCommit or restore them, or pass --allow-dirty for a throwaway build.\nA release archive has to be something a commit describes.\n")
		return exitMisuse
	}

	result, err := release.Package(root, *version, *outDir, assets...)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	built := attribution.Commit
	if len(attribution.Dirty) > 0 {
		built += " (with uncommitted changes)"
	}

	fmt.Fprintf(out, "%s\n%s\n\nbuilt from %s\n%s  %s\n",
		result.Archive, result.Sums, built, result.SHA256, filepath.Base(result.Archive))
	return exitOK
}

// multiFlag collects a flag given more than once.
type multiFlag []string

func (m *multiFlag) String() string { return strings.Join(*m, ", ") }

func (m *multiFlag) Set(value string) error {
	if strings.TrimSpace(value) == "" {
		return fmt.Errorf("an empty path is not an asset")
	}
	*m = append(*m, value)
	return nil
}
