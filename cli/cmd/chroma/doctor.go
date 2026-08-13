package main

import (
	"flag"
	"fmt"
	"os"

	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/report"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// cmdDoctor reports whether the Chroma on this machine is healthy — that
// question, and not "does the directory I happen to be standing in contain a
// components/ folder". `--tree` used to default to `.`, so `cd /tmp && chroma
// doctor` answered "no components directory in ." and exited 2 against a working
// installation. With no flag it now finds the installation the way every other
// managed command does.
//
// The report has two halves and the line between them is the point: Chroma's own
// tooling can be broken, everything else belongs to the person running this — so
// a missing kubectl prints `not found`, not `ERROR`, and does not change the
// exit code.
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

	report.Banner(out)

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

	// The components in force, not every component the release ships: somebody who
	// turned Kubernetes off is not missing kubectl, they do not need it. A
	// checkout has no selection to narrow by, so there it is the whole contract.
	ids := enabled
	if ids == nil {
		ids = loaded.IDs()
	}
	tools := detect.Tools(loaded, ids, nil, nil)

	own, external := detect.Split(tools)

	if len(own) > 0 {
		fmt.Fprint(out, "\nChroma\n\n")
		report.Requirements(out, own)
	}
	report.External(out, external)

	// Asked of the same rule the installer refuses on, rather than worked out
	// again from what was just printed. A report that decides for itself what
	// counts as broken is a second opinion, and the exit code is not the place
	// for one.
	if detect.Blocking(own) {
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
		dir, code := contractIn(root, errOut)
		if code != exitOK {
			return "", nil, code
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
