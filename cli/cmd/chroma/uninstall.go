package main

import (
	"flag"
	"fmt"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// cmdUninstall removes what Chroma made and gives back what it borrowed.
//
// One operation and no levels. `--purge` beside a plain `uninstall` asks
// somebody to guess which of two destructive things they meant, and the honest
// alternative is cheaper: show the exact list of paths and let them read it
// before agreeing.
//
// The rule the list follows: **what Chroma made for its own operation it may
// remove; what Chroma only moved aside, because it belonged to somebody
// already, it gives back.** So the plugins, the Mason packages, the parsers,
// the cache, the kept generations and the selection all go — and a
// configuration that was in Neovim's directory before `--default` took it over
// is restored, never deleted.
func cmdUninstall(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("uninstall", flag.ContinueOnError)
	set.SetOutput(errOut)

	dryRun := set.Bool("dry-run", false, "print the plan and remove nothing")
	assumeYes := set.Bool("yes", false, "remove without asking")
	nonInteractive := set.Bool("non-interactive", false, "never ask")

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

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

	// Before the plan, not after it: a destructive list nobody is going to act
	// on reads as a threat rather than as information.
	if err := install.RefuseSymlinkedConfiguration(current.ConfigDir); err != nil {
		fmt.Fprintln(errOut, err)
		return exitMisuse
	}

	// Before the plan is built, because the plan is printed and a plan that
	// offers to remove somebody's own configuration is the lie this whole
	// milestone is about. A run killed between the restore and the record
	// leaves exactly that disagreement behind.
	repaired, why, err := install.ReconcileHandover(current)
	if err != nil {
		fmt.Fprintln(errOut, err)
		fmt.Fprint(errOut, "Nothing was changed.\n")
		return exitFailed
	}
	if why != "" {
		fmt.Fprintf(out, "%s\n\n", why)
		current = repaired
	}

	plan := install.PlanUninstall(paths, current)

	fmt.Fprint(out, "Uninstall Chroma Neovim\n\n")
	fmt.Fprintf(out, "  Version       %s\n\n", describeVersionOf(current.Version))
	fmt.Fprint(out, "Remove:\n")
	for _, path := range plan.Remove {
		fmt.Fprintf(out, "  %s\n", path)
	}

	if len(plan.GiveBack) > 0 {
		fmt.Fprint(out, "\nGive back:\n")
		for _, one := range plan.GiveBack {
			fmt.Fprintf(out, "  %s\n", one.Backup)
			fmt.Fprintf(out, "    back to %s — this is the %s you had before Chroma,\n", one.Original, one.Kind)
			fmt.Fprint(out, "    and it is given back rather than removed.\n")
		}
	}

	fmt.Fprint(out, "\nExternal tools will not be removed. Neither will Neovim.\n")

	if *dryRun {
		fmt.Fprint(out, "\nNothing was removed: this is a dry run.\n")
		return exitOK
	}

	if !*assumeYes && !*nonInteractive {
		if !asked(out, "\nContinue? [y/N] ") {
			fmt.Fprint(out, "Nothing was changed.\n")
			return exitDeclined
		}
	}

	installer := &install.Installer{Sink: lineSink{out: out}}

	removal, err := installer.Uninstall(paths, current)
	if err != nil {
		fmt.Fprintln(errOut, err)
		if removal.Restored != "" {
			fmt.Fprintf(errOut, "\n%s was put back at %s.\n", removal.Restored, plan.RestoreTo)
		}
		fmt.Fprintf(errOut, "%d of %d paths were removed; the rest are named above.\n", len(removal.Removed), len(plan.Remove))
		return exitFailed
	}

	fmt.Fprintf(out, "\nChroma Neovim is uninstalled. %d paths removed.\n", len(removal.Removed))
	if removal.Restored != "" {
		fmt.Fprintf(out, "The configuration you had before Chroma is back at %s.\n", plan.RestoreTo)
	}
	return exitOK
}
