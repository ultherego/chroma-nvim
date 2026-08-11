package report

import (
	"bytes"
	"io"
	"regexp"
	"strings"
	"testing"

	"charm.land/lipgloss/v2"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// A contract built for the occasion, so these cases do not change meaning when
// the shipped one does.
func fixture() component.Set {
	return component.Set{
		"core": {ID: "core", Name: "Core", Tools: component.Tools{
			Required:    []component.Tool{{ID: "git", Reason: "plugins"}},
			Recommended: []component.Tool{{ID: "fzf", Reason: "pickers"}},
		}},
		"terraform": {ID: "terraform", Name: "Terraform", Requires: []string{"core"}, Tools: component.Tools{
			Required: []component.Tool{{Any: []string{"terraform", "tofu"}, Reason: "the runner"}},
		}},
		"kubernetes": {ID: "kubernetes", Name: "Kubernetes", Requires: []string{"core"}, Tools: component.Tools{
			Required: []component.Tool{{ID: "kubectl", Reason: "views"}},
		}},
	}
}

// on builds a plan for a machine where exactly these commands exist, and each
// answers with a version new enough for whatever asked for it.
func on(requested []string, names ...string) plan.Plan {
	present := map[string]bool{}
	for _, name := range names {
		present[name] = true
	}
	return plan.Build(fixture(), requested, func(set component.Set, enabled []string) []detect.Tool {
		return detect.Tools(set, enabled,
			func(name string) bool { return present[name] },
			func(string) string { return "9.9.9" })
	})
}

// drawn runs one of the renderers into a buffer, with no colour and no width,
// which is what a pipe and a file get.
func drawn(t *testing.T, render func(io.Writer)) string {
	t.Helper()

	t.Cleanup(seam(nil, nil))
	var buffer bytes.Buffer
	render(&buffer)
	return buffer.String()
}

// seam replaces what this package asks about the far end, and returns the
// undo. Nil means the plain answer: no environment, and no width.
func seam(environ []string, width func(io.Writer) int) func() {
	oldEnvironment, oldRoom := environment, room

	environment = func() []string { return environ }
	room = width
	if width == nil {
		room = func(io.Writer) int { return 0 }
	}

	return func() { environment, room = oldEnvironment, oldRoom }
}

// cell finds the table row a tool is on. Only lines inside a table, so that a
// name mentioned in the prose above one is not mistaken for its row.
func cell(t *testing.T, text, name string) string {
	t.Helper()

	for _, line := range strings.Split(text, "\n") {
		if strings.HasPrefix(line, "│") && strings.Contains(line, name) {
			return line
		}
	}
	t.Fatalf("no table row for %q:\n%s", name, text)
	return ""
}

var escapes = regexp.MustCompile("\x1b\\[[0-9;]*m")

func TestPlanNamesWhatWouldBeInstalledAndWhatIsMissing(t *testing.T) {
	out := drawn(t, func(w io.Writer) { Plan(w, on([]string{"terraform"}, "git")) })

	for _, want := range []string{"core, terraform", "pulled in as a dependency"} {
		if !strings.Contains(out, want) {
			t.Errorf("the plan does not mention %q:\n%s", want, out)
		}
	}

	fzf := cell(t, out, "fzf")
	if !strings.Contains(fzf, "recommended") || !strings.Contains(fzf, "not found") {
		t.Errorf("the row for fzf does not say it is recommended and not found:\n%s", fzf)
	}
	if git := cell(t, out, "git"); !strings.Contains(git, "ok") {
		t.Errorf("git is on this machine and the plan does not say so:\n%s", git)
	}
}

// The user's own tools are named but not counted. A row in the table of what
// Chroma needs would read as a checklist to satisfy before installing, which is
// exactly what it is not.
func TestPlanNamesExternalToolsWithoutCountingThem(t *testing.T) {
	out := drawn(t, func(w io.Writer) { Plan(w, on([]string{"terraform"}, "git")) })

	for _, want := range []string{"terraform/tofu", "does not install these"} {
		if !strings.Contains(out, want) {
			t.Errorf("the plan does not mention %q:\n%s", want, out)
		}
	}
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(line, "│") && strings.Contains(line, "tofu") {
			t.Errorf("an external tool has a row in the table of what Chroma needs:\n%s", line)
		}
	}
}

// A plan that would install nothing said "Missing nothing", which is true and
// reads as success. The exit code disagreed with the text.
func TestPlanSaysWhenNothingWouldBeInstalled(t *testing.T) {
	out := drawn(t, func(w io.Writer) { Plan(w, on([]string{"vault"})) })

	if !strings.Contains(out, "nothing would be installed") {
		t.Errorf("an empty plan should say so:\n%s", out)
	}
	if strings.Contains(out, "│") {
		t.Errorf("an empty plan should not draw a table of tools:\n%s", out)
	}
}

func TestPlanOnAReadyMachineSaysNothingIsMissing(t *testing.T) {
	out := drawn(t, func(w io.Writer) { Plan(w, on([]string{"core"}, "git", "fzf")) })

	if strings.Contains(out, "not found") || strings.Contains(out, "too old") {
		t.Errorf("everything is here and the plan says otherwise:\n%s", out)
	}
	for _, name := range []string{"git", "fzf"} {
		if !strings.Contains(cell(t, out, name), "ok") {
			t.Errorf("%s is here and its row does not say ok:\n%s", name, out)
		}
	}
}

// The wording is the substance: an absent kubectl is a fact about the machine,
// and a report that shouts about it says the installation is broken when it is
// not.
func TestExternalToolsAreReportedWithoutCallingThemAFailure(t *testing.T) {
	_, external := detect.Split(on([]string{"kubernetes"}, "git").Tools)

	out := drawn(t, func(w io.Writer) { External(w, external) })

	if !strings.Contains(out, "not found") {
		t.Errorf("the report does not say what is not found:\n%s", out)
	}
	if !strings.Contains(out, "does not install") {
		t.Errorf("the report does not say Chroma will not install these:\n%s", out)
	}
	for _, shouted := range []string{"ERROR", "FAIL", "missing dependency", "required but"} {
		if strings.Contains(out, shouted) {
			t.Errorf("the report says %q about a tool that is simply the user's to install:\n%s", shouted, out)
		}
	}
	if !strings.Contains(cell(t, out, "kubectl"), "kubernetes") {
		t.Errorf("the report does not say which component wants kubectl:\n%s", out)
	}
}

// The property the whole renderer rests on: colour repeats what the words
// already say. Anything encoded only in a colour is invisible to NO_COLOR, to a
// pipe, and to a person who cannot tell red from grey — so the two runs must
// differ in escape sequences and in nothing else.
func TestNothingIsSaidInColourAlone(t *testing.T) {
	own, external := detect.Split(on([]string{"terraform", "kubernetes"}, "git").Tools)

	render := func(w io.Writer) {
		Banner(w)
		Requirements(w, own)
		External(w, external)
	}

	defer seam([]string{"CLICOLOR_FORCE=1", "TERM=xterm-256color"}, nil)()
	var coloured bytes.Buffer
	render(&coloured)

	defer seam(nil, nil)()
	var plain bytes.Buffer
	render(&plain)

	if !strings.Contains(coloured.String(), "\x1b[") {
		t.Fatal("the colour seam did not colour anything, so this measures nothing")
	}
	if got := escapes.ReplaceAllString(coloured.String(), ""); got != plain.String() {
		t.Errorf("colour carries something the words do not:\n%s\nwant:\n%s", got, plain.String())
	}
}

func TestAPipeGetsNoEscapeSequences(t *testing.T) {
	own, _ := detect.Split(on([]string{"core"}, "git").Tools)

	// A terminal's own environment, and an output that is a buffer rather than a
	// terminal. What decides is the far end, not what the environment would
	// allow.
	defer seam([]string{"TERM=xterm-256color", "COLORTERM=truecolor"}, nil)()
	var buffer bytes.Buffer
	Banner(&buffer)
	Requirements(&buffer, own)

	if strings.Contains(buffer.String(), "\x1b") {
		t.Errorf("something drew escape sequences into a pipe:\n%q", buffer.String())
	}
}

// A table wider than the terminal is a table with its right-hand border
// somewhere on the next line, which is not a border. The sentences between the
// tables are held to the same rule: one of them used to be broken at a fixed
// column and ran off the edge of anything narrower than eighty.
func TestANarrowTerminalKeepsEverythingOnScreen(t *testing.T) {
	built := on([]string{"terraform", "kubernetes"}, "git")
	own, external := detect.Split(built.Tools)

	const narrow = 44
	defer seam(nil, func(io.Writer) int { return narrow })()
	var buffer bytes.Buffer
	Banner(&buffer)
	Plan(&buffer, built)
	Requirements(&buffer, own)
	External(&buffer, external)

	for _, line := range strings.Split(strings.TrimRight(buffer.String(), "\n"), "\n") {
		if width := lipgloss.Width(line); width > narrow {
			t.Errorf("a line is %d columns wide on a %d-column terminal: %q", width, narrow, line)
		}
	}
	if !strings.Contains(buffer.String(), "git") {
		t.Errorf("squeezing the table lost the tool it is about:\n%s", buffer.String())
	}
}

// Squeezing a table by a few columns hands back, on lipgloss v2.0.5, a frame
// with its right-hand border gone and a cell shortened with no ellipsis to say
// so: at every width from 45 to 41 for a table that wants 46, `git 9.9.9` came
// back as `git 9.9`. Six columns is the range that was measured. A report that
// quietly drops
// characters is a report that cannot be trusted about a version number, so
// whatever the library does with a given width, what leaves this package is a
// whole table with everything still in it.
func TestASqueezedTableKeepsItsFrameAndItsContents(t *testing.T) {
	headers := []string{"Tool", "Need", "State", "Detail"}
	rows := [][]string{
		{"git", "required", "ok", "git 9.9.9"},
		{"fzf", "recommended", "not found", "pickers"},
	}

	natural := lipgloss.Width(grid(headers, rows, nil, 0))

	for asked := natural - 1; asked >= natural-6; asked-- {
		drawn := grid(headers, rows, nil, asked)

		if !whole(drawn) {
			t.Errorf("the table lost its frame when squeezed to %d columns:\n%s", asked, drawn)
		}
		if got := lipgloss.Width(drawn); got > asked {
			t.Errorf("the table is %d columns wide after being squeezed to %d:\n%s", got, asked, drawn)
		}
		if !strings.Contains(drawn, "9.9.9") {
			t.Errorf("squeezing to %d columns lost part of a version number:\n%s", asked, drawn)
		}
	}
}

func TestAWideTerminalIsNotStretchedToFit(t *testing.T) {
	own, _ := detect.Split(on([]string{"core"}, "git").Tools)

	defer seam(nil, func(io.Writer) int { return 200 })()
	var buffer bytes.Buffer
	Requirements(&buffer, own)

	for _, line := range strings.Split(strings.TrimRight(buffer.String(), "\n"), "\n") {
		if width := lipgloss.Width(line); width > 120 {
			t.Errorf("the table was stretched to %d columns because the terminal was wide: %q", width, line)
		}
	}
}

// Clearing is for screens. A pipe has nothing to clear, and a file that starts
// with an escape sequence is a log somebody has to strip before reading it.
func TestTheScreenIsClearedOnlyWhereThereIsOne(t *testing.T) {
	var piped bytes.Buffer
	func() {
		defer seam(nil, nil)()
		Clear(&piped)
	}()
	if piped.Len() != 0 {
		t.Errorf("something was written into a pipe: %q", piped.String())
	}

	var screen bytes.Buffer
	func() {
		defer seam(nil, func(io.Writer) int { return 80 })()
		Clear(&screen)
	}()
	if screen.Len() == 0 {
		t.Error("a terminal was not cleared")
	}

	// The scrollback is the user's. `ESC[3J` is the sequence that deletes it.
	if strings.Contains(screen.String(), "[3J") {
		t.Errorf("clearing the screen threw away the scrollback: %q", screen.String())
	}
}

func TestANarrowTerminalGetsTheNameInsteadOfTheWordmark(t *testing.T) {
	defer seam(nil, func(io.Writer) int { return 20 })()
	var buffer bytes.Buffer
	Banner(&buffer)

	if strings.Contains(buffer.String(), "█") {
		t.Errorf("the wordmark was drawn into a terminal too narrow to hold it:\n%s", buffer.String())
	}
	if !strings.Contains(buffer.String(), "Chroma Neovim") {
		t.Errorf("the name is not there either:\n%q", buffer.String())
	}
}

func TestAWideEnoughTerminalGetsTheWordmark(t *testing.T) {
	defer seam(nil, func(io.Writer) int { return 100 })()
	var buffer bytes.Buffer
	Banner(&buffer)

	if !strings.Contains(buffer.String(), "█") {
		t.Errorf("no wordmark on a 100-column terminal:\n%s", buffer.String())
	}
	if width := lipgloss.Width(buffer.String()); width > 100 {
		t.Errorf("the wordmark is %d columns wide", width)
	}
}
