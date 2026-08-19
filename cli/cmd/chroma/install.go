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
	"github.com/ultherego/chroma-nvim/cli/internal/report"
	"github.com/ultherego/chroma-nvim/cli/internal/theme"
)

// cmdInstall places a Chroma Neovim on this machine, in the shape cli/DESIGN.md
// describes: resolve where it goes, prepare what to install, read its contract,
// build a plan, show it, ask, and only then let the installer touch anything.
// Everything before the confirmation is free to fail; everything after it is a
// transaction.
func cmdInstall(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("install", flag.ContinueOnError)
	set.SetOutput(errOut)

	dryRun := set.Bool("dry-run", false, "build the plan, print it, and write nothing")
	components := set.String("components", "", "comma-separated optional components; core is always installed")
	profile := set.String("profile", "", "a named set of components: "+strings.Join(install.ProfileNames(), ", "))
	chosenTheme := set.String("theme", "", "the colourscheme, out of what the release offers; unset takes the release's default")
	sourceTree := set.String("source-tree", "", "install from a checkout instead of a release (developer-only)")
	version := set.String("version", "", "the release to install")
	useDefault := set.Bool("default", false, "take over ~/.config/nvim, backing up what is there")
	nonInteractive := set.Bool("non-interactive", false, "never ask; anything unanswered is misuse")
	plain := set.Bool("plain", false, "ask in printed lines instead of selectors, even on a terminal (also CHROMA_PLAIN=1)")
	assumeYes := set.Bool("yes", false, "accept the final plan without asking")

	if err := set.Parse(args); err != nil {
		return exitMisuse
	}

	opts := install.Options{
		Version:        *version,
		SourceTree:     *sourceTree,
		UseDefault:     *useDefault,
		Profile:        *profile,
		Theme:          *chosenTheme,
		NonInteractive: *nonInteractive,
		Plain:          *plain,
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

	// Above everything this command says, and not above the plan, which comes
	// after the questions. Misuse of the flags is still reported without one.
	// On a screen it starts from a clean one; not in a pipe or a file, where the
	// sequence would be noise in a log.
	report.Clear(out)
	report.Banner(out)

	// `chroma install` with nothing else used to refuse — "name a release with
	// --version" — and an installer whose plain form does not install is not an
	// installer. Set after Validate rather than as the flag's default, which
	// would make every --source-tree run look like both were asked for.
	if opts.Version == "" && opts.SourceTree == "" {
		opts.Version = release.Latest
	}

	// One managed installation per user, refused before anything is downloaded,
	// staged or moved. A second one produced a state this CLI could not get out
	// of — measured: with an isolated and a `--default` installation both
	// recorded, update, components, rollback and uninstall all refused
	// afterwards. Naming which installation each command means would still be
	// wrong in one place a flag cannot reach: the component selection is one
	// document per user, shared by both.
	if code := refuseASecondInstallation(errOut); code != exitOK {
		return code
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

	// What this release can draw, asked of the release rather than assumed. A
	// tree without the file is a release from before the colourscheme was a
	// choice, which is an empty catalogue and no question — and not an error.
	catalogue, _, err := theme.LoadCatalogue(prepared.Root)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitFailed
	}

	// The interactive flow, and only when there is something it has to ask.
	// A run that names its components is being driven by flags, and asking it
	// where to go would break every scripted install that answers the final
	// question with --yes and nothing else. The colourscheme is inside that gate
	// rather than beside it, for the same reason: such a run gets the release's
	// own default, which is an answer, and `--theme` is how it says otherwise.
	if opts.Selected == nil && opts.Profile == "" && !opts.NonInteractive {
		opts, err = askInteractively(opts, loaded, catalogue, os.Stdin, out)
		if err != nil {
			return refused(err, out, errOut)
		}

		// The questions are over. Said here rather than at the top of the plan,
		// because a run that asked nothing has the wordmark's own blank line
		// above it already and would get two.
		fmt.Fprintln(out)

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

	// Resolved here as well as inside the installer, and deliberately: a
	// `--theme` naming something this release does not have is misuse, and
	// misuse is reported before a plan is drawn rather than after somebody has
	// agreed to one.
	pickedTheme, err := opts.ThemeChoice(catalogue)
	if err != nil {
		fmt.Fprintln(errOut, err)
		return exitMisuse
	}

	built := plan.Build(loaded, append([]string{"core"}, selected...), describeTools)
	renderPlan(out, opts, paths, prepared, built, catalogue, pickedTheme)

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
	// and finding that out after the tree is placed is too late. External tools
	// are not part of this: choosing the kubernetes component asks for Chroma's
	// Kubernetes features, not for kubectl.
	if !built.Complete() {
		fmt.Fprint(errOut, "\nSomething Chroma itself needs is missing. Install it, or choose fewer components.\n")
		return exitPreflight
	}

	if !confirmed(opts, out) {
		fmt.Fprint(out, "Nothing was changed.\n")
		return exitDeclined
	}

	// Taken here and not before: until the interactive flow has answered, this
	// does not know which installation it is about to touch. Everything before
	// this point asks questions, downloads and prints; everything after it
	// mutates, so a dry run leaves no lock behind either. What could have changed
	// while somebody read the plan is revalidated inside the transaction.
	held, code := locked(errOut)
	if code != exitOK {
		return code
	}
	defer held.Release()

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
	report.External(out, external)

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
		prepared, err := releaseSource(opts.Version).Prepare(ctx)
		if err != nil {
			fmt.Fprintln(errOut, err)
			return install.PreparedSource{}, exitFailed
		}
		return prepared, exitOK

	default:
		// Unreachable from cmdInstall, which fills in `latest` above. Kept as a
		// refusal rather than a silent default so that a second caller cannot
		// acquire one by accident.
		fmt.Fprintf(errOut, "nothing to install: name a release with --version (or --version %s), or a checkout with --source-tree.\n", release.Latest)
		return install.PreparedSource{}, exitMisuse
	}
}

// refuseASecondInstallation stops before a machine can end up with two.
func refuseASecondInstallation(errOut *os.File) int {
	found, code := recorded(errOut)
	if code != exitOK {
		return code
	}
	if len(found) == 0 {
		return exitOK
	}

	fmt.Fprint(errOut, "Chroma is already installed on this machine:\n")
	for _, one := range found {
		fmt.Fprintf(errOut, "  %s\n", one.state.ConfigDir)
	}
	fmt.Fprint(errOut, "There is one managed installation per user. Move that one forward with `chroma update`, change what is in it with `chroma components`, or remove it with `chroma uninstall` and install again.\n")
	return exitMisuse
}

// releaseSource turns a version into a tree on this machine. A package variable
// so a test does not have to reach the network to find out which version this
// command asked for. Replaced in tests, never in a released binary.
var releaseSource = func(version string) preparer {
	return release.GitHubSource{Version: version}
}

// preparer is the half of a source this command uses.
type preparer interface {
	Prepare(context.Context) (install.PreparedSource, error)
}

// renderPlan prints what would happen, before anything does.
func renderPlan(out *os.File, opts install.Options, paths install.Paths, prepared install.PreparedSource, built plan.Plan, catalogue theme.Catalogue, picked string) {
	fmt.Fprintf(out, "Nothing has been written yet. This is what installing would do.\n\n")

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

	// Only when there is one. A release from before the colourscheme was a
	// choice has nothing to say here, and a line reading "Colourscheme" with
	// nothing after it is worse than no line.
	if picked != "" {
		shown := picked
		if one, found := catalogue.Get(picked); found && one.Name != "" {
			shown = one.Name
		}
		fmt.Fprintf(out, "  Colourscheme  %s\n", shown)
	}
	fmt.Fprintln(out)
	report.Plan(out, built)
}

// confirmed asks, unless it has been told not to.
func confirmed(opts install.Options, out *os.File) bool {
	if opts.AssumeYes || opts.NonInteractive {
		return true
	}
	return asked(out, "\nProceed? [y/N] ")
}

// asked puts one yes-or-no question on stdin.
//
// Anything that is not yes is no, including a read that fails: a pipe with
// nothing left in it has not agreed to replace somebody's editor.
func asked(out *os.File, prompt string) bool {
	fmt.Fprint(out, prompt)

	answer, err := bufio.NewReader(os.Stdin).ReadString('\n')
	if err != nil && strings.TrimSpace(answer) == "" {
		return false
	}

	switch strings.ToLower(strings.TrimSpace(answer)) {
	case "y", "yes":
		return true
	default:
		return false
	}
}

// logFile is where this operation's detail goes — every line the editor printed
// while installing plugins and compiling parsers.
//
// Opened at the first line written to it, not here, and the reason is a
// measurement: on a `--default` installation the log directory sits under
// `~/.local/state/nvim`, which at this point is still somebody else's. Creating
// it eagerly left a Chroma log inside the user's own state directory, which the
// takeover then moved aside and handed back at uninstall with the log still in
// it. By the first write the borrowing has happened and the path is Chroma's.
//
// It returns an io.Writer rather than an *os.File: a nil *os.File assigned to an
// interface is not a nil interface, and the runner would write to it and panic.
func logFile(paths install.Paths, errOut *os.File) io.Writer {
	return &lazyLog{dir: paths.LogDir, errOut: errOut}
}

// lazyLog opens the log file the first time something is written to it.
type lazyLog struct {
	dir    string
	errOut *os.File

	handle io.Writer
	opened bool
}

func (l *lazyLog) Write(line []byte) (int, error) {
	if !l.opened {
		l.opened = true
		l.handle = l.open()
	}
	if l.handle == nil {
		// Said once, when it was tried. A run with nowhere to log is a run that
		// still installs.
		return len(line), nil
	}
	return l.handle.Write(line)
}

func (l *lazyLog) open() io.Writer {
	if err := os.MkdirAll(l.dir, 0o755); err != nil {
		fmt.Fprintf(l.errOut, "not writing a log: %v\n", err)
		return nil
	}

	name := filepath.Join(l.dir, fmt.Sprintf("install-%s.log", timestamp()))
	handle, err := os.OpenFile(name, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		fmt.Fprintf(l.errOut, "not writing a log: %v\n", err)
		return nil
	}
	fmt.Fprintf(l.errOut, "Log: %s\n", name)
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
