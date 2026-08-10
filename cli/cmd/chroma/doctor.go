package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// cmdDoctor reports whether the Chroma on this machine is healthy.
//
// That question, and not "does the directory I happen to be standing in contain
// a components/ folder". `--tree` used to default to `.`, so the ordinary
// invocation failed in every directory but a checkout — measured against a
// working managed installation:
//
//	$ cd /tmp && chroma doctor
//	no components directory in . — is that a Chroma Neovim tree?   (exit 2)
//
// With no flag it now finds the installation the way every other managed
// command does, reads that installation's own contract, and reports the
// components its owner actually chose. `--tree` remains, as what it always
// really was: an explicit read-only override for somebody working on a checkout,
// and there it reports the whole contract because there is no selection to
// narrow it by.
//
// The report has two halves and the line between them is the point. Chroma's
// own tooling is the half that can be broken: without git there are no plugins.
// Everything else — terraform, kubectl, helm, ansible, aws, docker — belongs to
// the person running this, and its absence is reported as a fact about the
// machine rather than as a fault in the installation. So a missing kubectl
// prints `not found`, not `ERROR`, and does not change the exit code.
func cmdDoctor(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("doctor", flag.ContinueOnError)
	set.SetOutput(errOut)

	// No default. An empty string is the question "which installation?", and a
	// default of "." was the answer "whichever directory you are in", which is
	// not a question anybody asked.
	root := set.String("tree", "", "read a checkout instead of the installation on this machine (developer-only)")
	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	dir, enabled, code := subject(*root, out, errOut)
	if code != exitOK {
		return code
	}

	loaded, code := load(dir, errOut)
	if code != exitOK {
		return code
	}

	system := detect.DetectSystem()
	fmt.Fprintf(out, "%s/%s", system.OS, system.Arch)
	if system.IsRoot {
		fmt.Fprint(out, ", running as root")
	}
	fmt.Fprint(out, "\n")

	// The components in force, not every component the release ships. Somebody
	// who turned Kubernetes off is not running a machine that is missing kubectl
	// — they are running a machine that does not need it, and a report saying
	// otherwise describes an installation they do not have.
	//
	// A checkout has no selection to narrow by, so there it is the whole
	// contract: that is what `--tree` is for.
	ids := enabled
	if ids == nil {
		ids = loaded.IDs()
	}
	tools := detect.Tools(loaded, ids, nil, nil)

	own, external := detect.Split(tools)

	broken := reportOwn(out, own)
	detect.RenderExternal(out, external)

	if broken {
		return exitPreflight
	}
	return exitOK
}

// subject decides what this report is about: an installation, or a checkout.
//
// Returns the components directory to read and the component ids in force, or
// nil ids when there is no selection because the subject is a tree.
func subject(root string, out, errOut *os.File) (string, []string, int) {
	if root != "" {
		dir := filepath.Join(root, "components")
		if info, err := os.Stat(dir); err != nil || !info.IsDir() {
			fmt.Fprintf(errOut, "no components directory in %s — is that a Chroma Neovim tree?\n", root)
			return "", nil, exitMisuse
		}
		fmt.Fprintf(out, "Reading %s, not an installation.\n\n", root)
		return dir, nil, exitOK
	}

	paths, current, code := managed(errOut)
	if code != exitOK {
		// managed() has already said there is none and how to get one. Adding a
		// second sentence about --tree here would offer a developer flag to
		// somebody who has just been told to install.
		return "", nil, code
	}

	dir := filepath.Join(current.ConfigDir, "components")
	if info, err := os.Stat(dir); err != nil || !info.IsDir() {
		fmt.Fprintf(errOut, "%s is recorded as a Chroma installation but has no components directory.\nRun `chroma install` again, or point at a checkout with --tree.\n", current.ConfigDir)
		return "", nil, exitFailed
	}

	fmt.Fprintf(out, "Chroma %s at %s\n\n", describeVersionOf(current.Version), current.ConfigDir)

	// The selection is read against the installation's own contract, so that a
	// component that was chosen and no longer exists is not silently counted.
	contract, code := load(dir, errOut)
	if code != exitOK {
		return "", nil, code
	}

	chosen, found, err := state.Load(paths.SelectionFile, contract)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return "", nil, exitFailed
	}
	if !found {
		// An installation with no selection document is core alone, which is
		// what the installer would have written. Reporting the whole contract
		// instead would describe components nobody enabled.
		return dir, []string{"core"}, exitOK
	}

	return dir, chosen.Enabled(contract), exitOK
}

// reportOwn prints Chroma's own tooling and says whether any of it is missing.
func reportOwn(out *os.File, tools []detect.Tool) bool {
	if len(tools) == 0 {
		return false
	}

	fmt.Fprint(out, "\nChroma\n")

	broken := false
	for _, tool := range tools {
		names := strings.Join(tool.Names, " or ")

		switch tool.Status {
		case detect.Present:
			fmt.Fprintf(out, "  ok         %-24s %s\n", names, describeVersion(tool))

		case detect.TooOld:
			broken = broken || tool.Blocking()
			fmt.Fprintf(out, "  too old    %-24s %s is %s, %s\n",
				names, tool.Found, describe(tool.Version), want(component.Tool{Version: tool.Want}))
			fmt.Fprintf(out, "             %s\n", tool.Reason)

		case detect.Absent:
			broken = broken || tool.Blocking()
			fmt.Fprintf(out, "  not found  %-24s %s — %s\n", names, tool.Level, tool.Reason)
		}
	}

	return broken
}

// describeVersion says what answered, and what it said.
func describeVersion(tool detect.Tool) string {
	if tool.Version == "" {
		return tool.Found
	}
	return fmt.Sprintf("%s %s", tool.Found, tool.Version)
}

func describe(version string) string {
	if version == "" {
		return "a version it would not report"
	}
	return version
}

func want(tool component.Tool) string {
	v := tool.Version
	switch {
	case v == nil:
		return "and that is enough"
	case v.Min != "" && v.Max != "":
		return "and " + v.Min + " to " + v.Max + " is required"
	case v.Min != "":
		return "and at least " + v.Min + " is required"
	case v.Max != "":
		return "and at most " + v.Max + " is required"
	default:
		return "and that is enough"
	}
}
