package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
	"github.com/ultherego/chroma-nvim/cli/internal/release"
	"github.com/ultherego/chroma-nvim/cli/internal/report"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// cmdUpdate replaces a managed installation with another release.
//
// It asks nothing about components. What somebody chose is a decision with a
// longer life than any release, and re-asking it on every update is how a
// person ends up with a different editor because they pressed return too
// quickly. The selection document is read, validated against the contract of
// the release being installed, and carried over — and if the new release no
// longer has a component that was chosen, that is a refusal before anything
// moves, not a silent drop.
func cmdUpdate(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("update", flag.ContinueOnError)
	set.SetOutput(errOut)

	version := set.String("version", release.Latest, "the release to update to")
	dryRun := set.Bool("dry-run", false, "say what would happen, and write nothing")
	assumeYes := set.Bool("yes", false, "accept the plan without asking")
	nonInteractive := set.Bool("non-interactive", false, "never ask")

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	paths, current, code := managed(errOut)
	if code != exitOK {
		return code
	}

	// Read-only, and it runs for every invocation: what a real run would repair
	// is described here and done below. A dry run must leave this machine
	// exactly as it found it, and that includes the lock file.
	if code := foreseen(paths, current, out, errOut); code != exitOK {
		return code
	}

	// A real run takes the lock and repairs before it plans anything, because a
	// plan built against a topology an interrupted transaction left behind is a
	// plan about a machine that is about to change. A dry run does neither, and
	// therefore plans against what is actually there and says so.
	if !*dryRun {
		held, code := locked(errOut)
		if code != exitOK {
			return code
		}
		defer held.Release()

		if code := recovered(paths, current, out, errOut); code != exitOK {
			return code
		}

		// Recovery can move a generation and rewrite the record, so what the
		// rest of this works from is read again rather than remembered.
		paths, current, code = managed(errOut)
		if code != exitOK {
			return code
		}
	}

	// A developer installation came from a checkout, and there is no release to
	// move it forward to. Refusing is the honest answer; guessing a version for
	// a tree would produce an install state that is not true.
	if current.Source.Type != installstate.FromRelease {
		fmt.Fprintf(errOut, "%s was installed from %s, not from a release.\nThere is nothing to update it to; reinstall with `chroma install --version`.\n",
			current.ConfigDir, current.Source.Ref)
		return exitMisuse
	}

	target, err := releaseVersion(ctx, *version)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	// Asked before anything is downloaded. An installation already on the newest
	// release has nothing to do, and doing the whole transaction to arrive at
	// the same tree is a risk taken for no change.
	if target == current.Version {
		fmt.Fprintf(out, "Chroma %s is already installed at %s.\nalready up to date\n", current.Version, current.ConfigDir)
		return exitOK
	}

	prepared, err := releaseSource(target).Prepare(ctx)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}
	defer func() {
		if prepared.Cleanup != nil {
			_ = prepared.Cleanup()
		}
	}()

	loaded, code := load(filepath.Join(prepared.Root, "components"), errOut)
	if code != exitOK {
		return code
	}

	selected, code := carriedOver(paths, loaded, errOut)
	if code != exitOK {
		return code
	}

	built := plan.Build(loaded, append([]string{"core"}, selected...), describeTools)
	renderUpdate(out, current, target, prepared, built)

	if *dryRun {
		fmt.Fprint(out, "\nNothing was written: this is a dry run.\n")
		return exitOK
	}

	if !built.Complete() {
		fmt.Fprint(errOut, "\nSomething Chroma itself needs is missing. Install it and try again.\n")
		return exitPreflight
	}

	if !*assumeYes && !*nonInteractive {
		if !asked(out, "\nUpdate Chroma? [y/N] ") {
			fmt.Fprint(out, "Nothing was changed.\n")
			return exitDeclined
		}
	}

	installer := &install.Installer{
		Runner: install.ExecRunner{Log: logFile(paths, errOut)},
		Sink:   lineSink{out: out},
	}

	result, err := installer.Update(ctx, paths, prepared, loaded, selected, current)
	fmt.Fprintf(out, "\n%s\n", result.Describe())
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	fmt.Fprintf(out, "\n  current   %s\n", result.State.Version)
	if result.State.Previous != nil {
		fmt.Fprintf(out, "  previous  %s, kept at %s\n", describeGeneration(*result.State.Previous), result.State.Previous.Path)
	}

	_, external := detect.Split(detect.Tools(loaded, built.Components, nil, nil))
	report.External(out, external)

	return exitOK
}

// managed finds the one installation on this machine, and says so when there is
// not exactly one.
//
// Both placements are looked at rather than asked about: somebody updating does
// not want to remember which of them they chose a year ago. Two of them is the
// case worth refusing — acting on whichever was checked first would update an
// installation the user was not thinking of.
// releaseVersion says which release a request like `latest` names.
//
// A package variable for the same reason releaseSource is one: a test about
// what this command does before it downloads anything should not have to reach
// the network to get there.
var releaseVersion = func(ctx context.Context, version string) (string, error) {
	return release.GitHubSource{Version: version}.Resolve(ctx)
}

// recorded finds every Chroma installation this user has, in both shapes.
//
// Read-only, and it reports rather than judges: what to do about none, one or
// two of them is the caller's question. `managed` answers it for the commands
// that act on an installation; `install` asks it to find out whether there is
// already one.
func recorded(errOut *os.File) ([]installation, int) {
	var found []installation
	for _, useDefault := range []bool{false, true} {
		paths, err := install.ResolvePaths(useDefault)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return nil, exitFailed
		}

		state, ok, err := installstate.Load(paths.InstallState)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return nil, exitFailed
		}
		if ok {
			found = append(found, installation{paths, state})
		}
	}
	return found, exitOK
}

// installation is one recorded installation and where it lives.
type installation struct {
	paths install.Paths
	state installstate.State
}

// managed finds the one installation a lifecycle command is about.
//
// One, and there is deliberately no way to ask for a particular one of two:
// `install` refuses to make a second, so two is a state this CLI does not
// produce. It was produced before that refusal existed — an isolated
// installation and a `--default` one side by side left every lifecycle command
// answering "this cannot tell which you mean", with no flag in the product to
// resolve it. Measured, and the reason the refusal is where it is rather than
// here: by the time a command needs to know which installation to act on, the
// wrong one has already been made.
func managed(errOut *os.File) (install.Paths, installstate.State, int) {
	found, code := recorded(errOut)
	if code != exitOK {
		return install.Paths{}, installstate.State{}, code
	}

	switch len(found) {
	case 0:
		fmt.Fprint(errOut, "No Chroma installation is recorded on this machine.\nInstall one with `chroma install`.\n")
		return install.Paths{}, installstate.State{}, exitMisuse
	case 1:
		return found[0].paths, found[0].state, exitOK
	default:
		fmt.Fprint(errOut, "Two Chroma installations are recorded and this cannot tell which you mean:\n")
		for _, one := range found {
			fmt.Fprintf(errOut, "  %s\n", one.state.ConfigDir)
		}
		fmt.Fprint(errOut, "Remove one of them by hand and try again.\n")
		return install.Paths{}, installstate.State{}, exitMisuse
	}
}

// carriedOver reads the selection this installation already has.
//
// Refused rather than guessed at when it is not there. Assuming "core alone"
// would silently take away everything somebody chose, and assuming "everything"
// would install what they deliberately did not.
func carriedOver(paths install.Paths, set component.Set, errOut *os.File) ([]string, int) {
	selection, found, err := state.Load(paths.SelectionFile, set)
	if err != nil {
		fmt.Fprintf(errOut, "%v\nFix it, or reinstall with `chroma install`.\n", err)
		return nil, exitMisuse
	}
	if !found {
		fmt.Fprintf(errOut, "%s does not exist, so there is no component selection to carry over.\nReinstall with `chroma install` and choose again.\n", paths.SelectionFile)
		return nil, exitMisuse
	}

	// Validated against the contract of the release being installed, so a
	// component this release no longer has is a refusal before anything moves.
	var unknown []string
	for _, id := range selection.Selected {
		if set[id] == nil {
			unknown = append(unknown, id)
		}
	}
	if len(unknown) > 0 {
		fmt.Fprintf(errOut, "This release has no component %s, which %s selects.\nChange the selection before updating.\n",
			strings.Join(unknown, ", "), paths.SelectionFile)
		return nil, exitMisuse
	}

	return selection.Selected, exitOK
}

// renderUpdate prints what would change, before it does.
func renderUpdate(out *os.File, current installstate.State, target string, prepared install.PreparedSource, built plan.Plan) {
	fmt.Fprintf(out, "Nothing has been written yet. This is what updating would do.\n\n")
	fmt.Fprintf(out, "  Current       %s\n", current.Version)
	fmt.Fprintf(out, "  Available     %s\n", target)
	fmt.Fprintf(out, "  Location      %s\n", current.ConfigDir)
	if prepared.SHA256 != "" {
		fmt.Fprintf(out, "  Verified      %s\n", prepared.SHA256)
	}
	fmt.Fprint(out, "\n")

	report.Plan(out, built)

	fmt.Fprint(out, "\n  The component selection is kept as it is; update does not ask again.\n")
	fmt.Fprintf(out, "  %s is moved aside first, and stays as the previous generation.\n", current.ConfigDir)
}

func describeGeneration(generation installstate.Generation) string {
	if generation.Version == "" {
		return "an installation from a checkout"
	}
	return generation.Version
}
