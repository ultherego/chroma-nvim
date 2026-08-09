package main

import (
	"flag"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/release"
)

// cmdPackage builds the artefacts a release is made of.
//
// Developer-only, and it stays in the same binary rather than becoming a script
// for one reason: the release workflow has to build the archive with the code
// that was tested, not with a shell pipeline that happens to agree with it
// today. What goes in comes from install.RuntimeEntries, which is also what the
// installer copies when it stages a checkout — so a release and a development
// install are the same files.
func cmdPackage(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("package", flag.ContinueOnError)
	set.SetOutput(errOut)

	tree := set.String("tree", ".", "the configuration tree to package")
	version := set.String("version", "", "the version this release is, e.g. v1.0.0")
	outDir := set.String("out", "dist", "where to write the archive and SHA256SUMS")

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

	result, err := release.Package(root, *version, *outDir)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	fmt.Fprintf(out, "%s\n%s\n\n%s  %s\n",
		result.Archive, result.Sums, result.SHA256, filepath.Base(result.Archive))
	return exitOK
}
