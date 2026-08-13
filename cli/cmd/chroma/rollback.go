package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"sort"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
	"github.com/ultherego/chroma-nvim/cli/internal/report"
)

// cmdRollback puts the previous generation back. There is no `--version`:
// rollback has exactly one target, the generation the last update moved aside.
// If that directory is gone this refuses rather than fetching the tag again,
// which would be `install --version` wearing the wrong name.
//
// It moves the version and keeps the selection: different facts with different
// lifetimes.
func cmdRollback(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("rollback", flag.ContinueOnError)
	set.SetOutput(errOut)

	dryRun := set.Bool("dry-run", false, "say what would happen, and write nothing")
	assumeYes := set.Bool("yes", false, "roll back without asking")
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

	if current.Previous == nil {
		fmt.Fprintf(errOut, "%s has no previous generation to go back to.\nOnly an update leaves one behind.\n", current.ConfigDir)
		return exitMisuse
	}
	target := *current.Previous

	// Everything below refuses before a single directory moves. That is the
	// whole discipline of this command: a rollback that gets halfway is worse
	// than one that never started.
	if _, err := os.Stat(filepath.Join(target.Path, "init.lua")); err != nil {
		fmt.Fprintf(errOut, "The previous generation is no longer available at %s.\nThere is nothing to roll back to; install the release you want with `chroma install --version`.\n", target.Path)
		return exitMisuse
	}

	// The contract of the generation being restored, read from the directory
	// that was kept — not from the one running now, which is the one being left.
	restored, code := load(filepath.Join(target.Path, "components"), errOut)
	if code != exitOK {
		return code
	}

	installed, code := load(filepath.Join(current.ConfigDir, "components"), errOut)
	if code != exitOK {
		return code
	}

	selected, code := carriedOver(paths, installed, errOut)
	if code != exitOK {
		return code
	}

	if code := supported(selected, restored, target, errOut); code != exitOK {
		return code
	}

	built := plan.Build(restored, append([]string{"core"}, selected...), describeTools)

	fmt.Fprint(out, "Nothing has been written yet. This is what rolling back would do.\n\n")
	fmt.Fprintf(out, "  Current       %s\n", describeVersionOf(current.Version))
	fmt.Fprintf(out, "  Rollback to   %s\n", describeVersionOf(target.Version))
	fmt.Fprintf(out, "  Kept at       %s\n", target.Path)
	fmt.Fprintf(out, "  Location      %s\n\n", current.ConfigDir)
	report.Plan(out, built)
	fmt.Fprint(out, "\n  The component selection is kept as it is; a rollback moves the version.\n")
	fmt.Fprintf(out, "  %s becomes the generation to come back to.\n", describeVersionOf(current.Version))

	if *dryRun {
		fmt.Fprint(out, "\nNothing was written: this is a dry run.\n")
		return exitOK
	}

	if !built.Complete() {
		fmt.Fprint(errOut, "\nSomething Chroma itself needs is missing. Install it and try again.\n")
		return exitPreflight
	}

	if !*assumeYes && !*nonInteractive {
		if !asked(out, "\nRoll back? [y/N] ") {
			fmt.Fprint(out, "Nothing was changed.\n")
			return exitDeclined
		}
	}

	installer := &install.Installer{
		Runner: install.ExecRunner{Log: logFile(paths, errOut)},
		Sink:   lineSink{out: out},
	}

	result, err := installer.Rollback(ctx, paths, restored, selected, current)
	if err != nil {
		fmt.Fprintln(errOut, err)
		fmt.Fprintf(errOut, "The generation you were on is still the one installed.\n")
		return exitFailed
	}

	fmt.Fprintf(out, "\n  current   %s\n", describeVersionOf(result.State.Version))
	if result.State.Previous != nil {
		fmt.Fprintf(out, "  previous  %s, kept at %s\n", describeVersionOf(result.State.Previous.Version), result.State.Previous.Path)
	}
	fmt.Fprint(out, "\nRolling back again returns to where you were.\n")

	_, external := detect.Split(detect.Tools(restored, built.Components, nil, nil))
	report.External(out, external)

	return exitOK
}

// supported refuses a selection the generation being restored cannot run.
//
// Before anything moves, and naming what is in the way. The alternative is a
// rollback that succeeds into an editor which silently does less than it did,
// because a component it was told to enable does not exist in that release.
func supported(selected []string, restored component.Set, target installstate.Generation, errOut *os.File) int {
	var unknown []string
	for _, id := range selected {
		if restored[id] == nil {
			unknown = append(unknown, id)
		}
	}
	if len(unknown) == 0 {
		return exitOK
	}
	sort.Strings(unknown)

	fmt.Fprintf(errOut, "Cannot roll back to %s.\n\n", describeVersionOf(target.Version))
	fmt.Fprint(errOut, "The current component selection is not supported by that generation:\n\n")
	for _, id := range unknown {
		fmt.Fprintf(errOut, "  %s\n", id)
	}
	fmt.Fprint(errOut, "\nChange the component selection first, with `chroma components`.\n")
	return exitMisuse
}

func describeVersionOf(version string) string {
	if version == "" {
		return "an installation from a checkout"
	}
	return version
}
