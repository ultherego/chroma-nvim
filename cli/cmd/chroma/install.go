package main

import (
	"bufio"
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
	"github.com/ultherego/chroma-nvim/cli/internal/release"
	"github.com/ultherego/chroma-nvim/cli/internal/tui"
)

// cmdInstall places a Chroma Neovim on this machine.
//
// The shape is the one in cli/DESIGN.md: resolve where it goes, prepare what to
// install, read its contract, build a plan, show it, ask, and only then let the
// installer touch anything. Everything before the confirmation is free to fail,
// and everything after it is a transaction.
func cmdInstall(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("install", flag.ContinueOnError)
	set.SetOutput(errOut)

	dryRun := set.Bool("dry-run", false, "build the plan, print it, and write nothing")
	components := set.String("components", "", "comma-separated optional components; core is always installed")
	profile := set.String("profile", "", "a named set of components: "+strings.Join(install.ProfileNames(), ", "))
	sourceTree := set.String("source-tree", "", "install from a checkout instead of a release (developer-only)")
	version := set.String("version", "", "the release to install")
	useDefault := set.Bool("default", false, "take over ~/.config/nvim, backing up what is there")
	nonInteractive := set.Bool("non-interactive", false, "never ask; anything unanswered is misuse")
	assumeYes := set.Bool("yes", false, "accept the final plan without asking")

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	opts := install.Options{
		Version:        *version,
		SourceTree:     *sourceTree,
		UseDefault:     *useDefault,
		Profile:        *profile,
		NonInteractive: *nonInteractive,
		DryRun:         *dryRun,
		AssumeYes:      *assumeYes,
	}

	// Passed-and-empty is not the same as not passed, and the difference is the
	// one the selection document itself rests on: `--components ''` says "core
	// alone", while leaving the flag off says nothing at all.
	set.Visit(func(f *flag.Flag) {
		if f.Name != "components" {
			return
		}
		opts.Selected = []string{}
		for _, id := range strings.Split(*components, ",") {
			if trimmed := strings.TrimSpace(id); trimmed != "" {
				opts.Selected = append(opts.Selected, trimmed)
			}
		}
	})

	if err := opts.Validate(); err != nil {
		fmt.Fprintln(errOut, err)
		return exitMisuse
	}

	// Ctrl-C between here and the end of the transaction cancels the context,
	// which stops the child process and rolls the installation back.
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()

	prepared, code := prepareSource(ctx, opts, errOut)
	if code != exitOK {
		return code
	}
	defer func() {
		if prepared.Cleanup != nil {
			_ = prepared.Cleanup()
		}
	}()

	paths, err := install.ResolvePaths(opts.UseDefault)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}
	if err := install.RefuseSourceInsideTarget(prepared.Root, paths); err != nil {
		fmt.Fprintln(errOut, err)
		return exitMisuse
	}

	loaded, code := load(filepath.Join(prepared.Root, "components"), errOut)
	if code != exitOK {
		return code
	}

	// The interactive flow, and only when there is something it has to ask.
	// A run that names its components is being driven by flags, and asking it
	// where to go would break every scripted install that answers the final
	// question with --yes and nothing else.
	if opts.Selected == nil && opts.Profile == "" && !opts.NonInteractive {
		opts, err = tui.Ask(opts, loaded, os.Stdin, out)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return exitMisuse
		}

		// The placement question can change where this goes, so the paths and
		// the refusal that depends on them are worked out again rather than
		// carried over from before the answer.
		paths, err = install.ResolvePaths(opts.UseDefault)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return exitFailed
		}
		if err := install.RefuseSourceInsideTarget(prepared.Root, paths); err != nil {
			fmt.Fprintln(errOut, err)
			return exitMisuse
		}
	}

	selected, err := opts.Selection(loaded)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitMisuse
	}

	built := plan.Build(loaded, append([]string{"core"}, selected...), onPath)
	renderPlan(out, opts, paths, prepared, built)

	if len(built.Unknown) > 0 {
		return exitMisuse
	}

	if opts.DryRun {
		fmt.Fprint(out, "\nNothing was written: this is a dry run.\n")
		if !built.Complete() {
			return exitPreflight
		}
		return exitOK
	}

	// One of Chroma's own tools missing means an installation that cannot work,
	// and finding that out after the configuration has been placed is finding
	// it out too late. External tools are not part of this: choosing the
	// kubernetes component asks for Chroma's Kubernetes features, not for
	// kubectl, and refusing to install an editor because a CLI is absent would
	// be Chroma deciding what belongs on somebody's machine.
	if !built.Complete() {
		fmt.Fprint(errOut, "\nSomething Chroma itself needs is missing. Install it, or choose fewer components.\n")
		return exitPreflight
	}

	if !confirmed(opts, out) {
		fmt.Fprint(out, "Nothing was changed.\n")
		return exitDeclined
	}

	installer := &install.Installer{
		Runner: install.ExecRunner{Log: logFile(paths, errOut)},
		Sink:   lineSink{out: out},
	}

	result, err := installer.Apply(ctx, opts, paths, prepared, loaded)
	fmt.Fprintf(out, "\n%s\n", result.Describe())
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	// Said at the end rather than at the start, and after the installation has
	// already succeeded, so that it reads as what it is: a note about the
	// machine, not a list of things to fix before Chroma will work.
	_, external := detect.Split(detect.Tools(loaded, built.Components, nil, nil))
	detect.RenderExternal(out, external)

	fmt.Fprintf(out, "\nRun it with:\n")
	if paths.AppName != "" {
		fmt.Fprintf(out, "  NVIM_APPNAME=%s nvim\n", paths.AppName)
	} else {
		fmt.Fprint(out, "  nvim\n")
	}
	return exitOK
}

// prepareSource turns the request into a tree on this machine.
func prepareSource(ctx context.Context, opts install.Options, errOut *os.File) (install.PreparedSource, int) {
	switch {
	case opts.SourceTree != "":
		absolute, err := filepath.Abs(opts.SourceTree)
		if err != nil {
			fmt.Fprintf(errOut, "--source-tree %s: %v\n", opts.SourceTree, err)
			return install.PreparedSource{}, exitMisuse
		}

		source := install.LocalSource{Root: absolute}
		prepared, err := source.Prepare(ctx)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return install.PreparedSource{}, exitMisuse
		}
		return prepared, exitOK

	case opts.Version != "":
		source := release.GitHubSource{Version: opts.Version}
		prepared, err := source.Prepare(ctx)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return install.PreparedSource{}, exitFailed
		}
		return prepared, exitOK

	default:
		fmt.Fprintf(errOut, "nothing to install: name a release with --version (or --version %s), or a checkout with --source-tree.\n", release.Latest)
		return install.PreparedSource{}, exitMisuse
	}
}

// renderPlan prints what would happen, before anything does.
func renderPlan(out *os.File, opts install.Options, paths install.Paths, prepared install.PreparedSource, built plan.Plan) {
	fmt.Fprintf(out, "Chroma Neovim will be installed.\n\n")

	switch {
	case prepared.Version == "":
		fmt.Fprintf(out, "  Source        %s (a checkout, not a release)\n", prepared.Root)
	case opts.Version == release.Latest:
		// Resolved before the plan is shown, and shown as both: a plan that
		// says "latest" is a plan nobody can check, and the version somebody
		// agreed to is the one that ends up in the install state.
		fmt.Fprintf(out, "  Requested     %s\n", release.Latest)
		fmt.Fprintf(out, "  Resolved      %s\n", prepared.Version)
	default:
		fmt.Fprintf(out, "  Release       %s\n", prepared.Version)
	}
	fmt.Fprintf(out, "  Location      %s\n", paths.ConfigDir)
	if paths.AppName != "" {
		fmt.Fprintf(out, "  Run with      NVIM_APPNAME=%s nvim\n", paths.AppName)
	}
	fmt.Fprintf(out, "  Selection     %s\n", paths.SelectionFile)
	fmt.Fprintln(out)
	built.Render(out)
}

// confirmed asks, unless it has been told not to.
func confirmed(opts install.Options, out *os.File) bool {
	if opts.AssumeYes || opts.NonInteractive {
		return true
	}

	fmt.Fprint(out, "\nProceed? [y/N] ")
	answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil {
		return false
	}

	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	default:
		return false
	}
}

// logFile opens this operation's log, and falls back to saying it could not.
//
// The log is where the detail goes — every line the editor printed while
// installing plugins and compiling parsers. The screen gets a status; this gets
// everything, so that a failure has somewhere to point.
// It returns an io.Writer rather than an *os.File on purpose: a nil *os.File
// assigned to an interface is not a nil interface, and the runner would write
// to it and panic.
func logFile(paths install.Paths, errOut *os.File) io.Writer {
	if err := os.MkdirAll(paths.LogDir, 0o755); err != nil {
		fmt.Fprintf(errOut, "not writing a log: %v\n", err)
		return nil
	}

	name := filepath.Join(paths.LogDir, fmt.Sprintf("install-%s.log", timestamp()))
	handle, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		fmt.Fprintf(errOut, "not writing a log: %v\n", err)
		return nil
	}
	fmt.Fprintf(errOut, "Log: %s\n", name)
	return handle
}

// lineSink prints progress as it happens.
type lineSink struct {
	out *os.File
}

func (s lineSink) Emit(event install.Event) {
	switch event.Status {
	case install.StatusStart:
		fmt.Fprintf(s.out, "  %s...\n", event.Step)
	case install.StatusDone:
		if event.Message != "" {
			fmt.Fprintf(s.out, "  %s: %s\n", event.Step, event.Message)
		}
	case install.StatusWarning:
		fmt.Fprintf(s.out, "  %s: %s\n", event.Step, event.Message)
	}
	// Progress lines are the child's own output. They go to the log, not to a
	// terminal somebody is watching for the one line that matters.
}

// timestamp names this operation's log. UTC, and sortable, so a directory of
// them reads in the order they happened.
func timestamp() string {
	return time.Now().UTC().Format("20060102T150405Z")
}
