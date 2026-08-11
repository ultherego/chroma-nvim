// Package report prints what the rest of the CLI has already worked out.
//
// One place for the printed shape of three things — the plan an installation
// would carry out, the state of Chroma's own tooling, and the state of the
// tools that belong to the user. `install` and `doctor` show the same facts
// about the same machine, and two renderers would be two chances to describe it
// differently; that disagreement is the shape of audit finding 11, where a plan
// and a report each decided for themselves whether a tool was usable.
//
// **Nothing here decides anything.** Everything it prints has already been
// worked out elsewhere — `detect.Tool.Status`, `detect.Tool.Blocking()`,
// `plan.Plan` — and its only freedom is how to show it. It chooses that a
// missing git is red and a missing kubectl is grey. It never chooses which of
// them stops an installation.
//
// Colour is never the message. Every state is a word first — `ok`, `too old`,
// `not found` — and the colour only repeats it, so a redirected file, a
// NO_COLOR environment and a monochrome terminal lose nothing. Nothing here
// asks whether colour is wanted either: everything is written through a writer
// that strips what the far end cannot show, which is one rule instead of a
// question at every call site.
package report

import (
	"fmt"
	"image/color"
	"io"
	"os"
	"strings"

	"charm.land/lipgloss/v2"
	"charm.land/lipgloss/v2/table"
	"github.com/charmbracelet/colorprofile"
	"github.com/charmbracelet/x/term"

	"github.com/ultherego/chroma-nvim/cli/internal/detect"
)

// The palette is Catppuccin Mocha, which is what the editor this installs is
// themed with and what the interactive selector already uses.
//
// Only three kinds of thing are coloured: the wordmark, the header row, and the
// one cell that carries a state. Everything else keeps the terminal's own
// foreground, so a light background stays readable — a table painted end to end
// in a dark theme's text colour would not be.
var (
	mauve = lipgloss.Color("#cba6f7")
	peach = lipgloss.Color("#fab387")
	green = lipgloss.Color("#a6e3a1")
	amber = lipgloss.Color("#f9e2af")
	red   = lipgloss.Color("#f38ba8")
	grey  = lipgloss.Color("#6c7086")
)

const (
	// state is the column that carries a tool's state, in both tables. They are
	// deliberately laid out the same way: one glance learns both.
	state = 2

	// narrowest is the width below which a table stops being one and a wrapped
	// sentence stops being readable. Nothing is drawn narrower than this; a
	// screen that small gets something too wide rather than something illegible.
	narrowest = 24
)

// environment is what the colour decision is made against. A variable so a test
// can be run on a machine whose owner has forced colour on, and still measure
// what a pipe would receive.
var environment = os.Environ

// colour returns a writer that keeps as much colour as the far end can show.
//
// A terminal gets it, a pipe and a file get none, and NO_COLOR is honoured
// without this package having to know the rule. That is the whole reason the
// tables are written through here rather than to the caller's writer directly.
func colour(w io.Writer) io.Writer {
	return colorprofile.NewWriter(w, environment())
}

// room is how much screen there is, in a variable.
//
// A test cannot hand this package a terminal, and without a seam the only width
// it could ever measure is "no width at all" — which is the case that needs the
// least deciding. The same lesson as the terminal check in internal/tui, where a
// mutant that asked the wrong question survived the whole suite until the
// predicate could be replaced.
var room = columns

// columns is how many columns there are to draw in, or zero when that is not a
// question — a file and a pipe have no width, and a table written into one is
// as wide as its content.
func columns(w io.Writer) int {
	file, ok := w.(*os.File)
	if !ok {
		return 0
	}
	width, _, err := term.GetSize(file.Fd())
	if err != nil || width <= 0 {
		return 0
	}
	return width
}

// paragraph lays a sentence out under an indent, wrapped to the screen.
//
// Prose broken at a fixed column is prose that is wrong somewhere: past the
// right-hand edge of a narrow terminal, and short of it on a wide one. The
// tables already ask the screen how much room there is, and the sentences
// between them ask the same question.
//
// Somewhere that has no width — a file, a pipe — gets a paragraph shaped for
// reading rather than one long line, which is what the hand-broken version was
// choosing too.
func paragraph(text string, indent, width int) string {
	if width <= 0 {
		width = 78
	}

	space := width - indent
	if space < narrowest {
		space = narrowest
	}

	pad := strings.Repeat(" ", indent)
	lines := strings.Split(lipgloss.Wrap(text, space, " -"), "\n")
	for i, line := range lines {
		lines[i] = pad + line
	}
	return strings.Join(lines, "\n")
}

// under writes a sentence beside a label, with the rest of it wrapped into the
// column the label ends in.
//
// The label is the whole indent — "  Components    " — so a line too long for
// the screen carries on underneath itself rather than under the label, which is
// how these lines have always been laid out by hand.
func under(w io.Writer, label, text string, width int) {
	said := paragraph(text, len(label), width)
	fmt.Fprintln(w, label+strings.TrimPrefix(said, strings.Repeat(" ", len(label))))
}

// grid draws one table of tools.
//
// The rows are already written; what this adds is the frame, the header, and
// the colour of the state cell — which comes from the tool itself, so that
// "this stops an installation" is shown by something that already knows, and is
// not worked out again here.
func grid(headers []string, rows [][]string, tools []detect.Tool, width int) string {
	drawn := table.New().
		Border(lipgloss.RoundedBorder()).
		BorderStyle(lipgloss.NewStyle().Foreground(grey)).
		Headers(headers...).
		Rows(rows...).
		StyleFunc(func(row, col int) lipgloss.Style {
			style := lipgloss.NewStyle().Padding(0, 1)
			switch {
			case row == table.HeaderRow:
				return style.Bold(true).Foreground(mauve)
			case col == state && row >= 0 && row < len(tools):
				return style.Foreground(shade(tools[row]))
			default:
				return style
			}
		})

	return fit(drawn, width)
}

// fit draws the table at the size its content wants, and squeezes it only when
// that would not fit on the screen.
//
// Setting a width unconditionally would stretch a four-column table across a
// 200-column terminal, which is harder to read than the narrow one. Setting
// none at all would push the right-hand border off the edge of an 80-column
// one, and a wrapped border is not a border.
//
// The squeezed result is then checked, which is not defensiveness. Measured on
// lipgloss v2.0.5, on a table whose content wants 46 columns: every width from
// 45 down to 41 came back with its right-hand border gone and a cell shortened
// with no ellipsis to say so — `git 9.9.9` became `git 9.9`. At 40 it wraps and
// is whole again. A report that quietly drops characters cannot be trusted
// about a version number, so the width used is the widest one that comes back
// whole, and a table too wide for the screen is preferred to a damaged one.
func fit(drawn *table.Table, width int) string {
	natural := drawn.String()
	if width <= 0 || lipgloss.Width(natural) <= width {
		return natural
	}

	for asked := width; asked >= narrowest; asked-- {
		if squeezed := drawn.Width(asked).String(); whole(squeezed) {
			return squeezed
		}
	}
	return natural
}

// whole reports whether a table still has the frame it was drawn with.
//
// The two corners on the right-hand side are the ones that go missing, and they
// are asked of the border this package sets rather than written out here, so
// that changing the border does not silently turn this check into "true".
func whole(drawn string) bool {
	border := lipgloss.RoundedBorder()
	lines := strings.Split(strings.TrimRight(drawn, "\n"), "\n")

	return len(lines) > 1 &&
		strings.Contains(lines[0], border.TopRight) &&
		strings.Contains(lines[len(lines)-1], border.BottomRight)
}

// shade is how a state looks, from what the tool already knows it is.
//
// Red is reserved for what actually stops an installation, and that is asked of
// `Blocking`, never worked out here. A missing kubectl is grey on purpose: it is
// a fact about the machine, the installation it belongs to is complete, and
// painting it the same red as a missing git would say the opposite in the one
// language people read before the words.
func shade(tool detect.Tool) color.Color {
	switch {
	case tool.Status == detect.Present:
		return green
	case tool.Blocking():
		return red
	case tool.External:
		return grey
	default:
		return amber
	}
}
