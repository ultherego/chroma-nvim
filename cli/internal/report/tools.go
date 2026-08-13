package report

import (
	"fmt"
	"io"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
)

// Requirements prints the state of Chroma's own tooling: the half of a machine
// that can stop an installation.
//
// The table only, with no heading and no sentence around it, because the two
// callers arrive at it from different places — a plan of what would happen, and
// a report on what is there — and each says so in its own words.
func Requirements(w io.Writer, tools []detect.Tool) {
	if len(tools) == 0 {
		return
	}

	rows := make([][]string, 0, len(tools))
	for _, tool := range tools {
		rows = append(rows, []string{
			strings.Join(tool.Names, " or "),
			tool.Level,
			own(tool.Status),
			detail(tool),
		})
	}

	fmt.Fprintln(colour(w), grid([]string{"Tool", "Need", "State", "Detail"}, rows, tools, room(w)))
}

// External prints the report on the user's own tools. One renderer, called by
// `doctor` and by the end of an installation. The wording is the substance:
// `not found`, never `ERROR`, because an installation with no kubectl on the
// machine is a complete installation — and the sentence above the table says so,
// which is why it lives here rather than at each call site.
func External(w io.Writer, tools []detect.Tool) {
	if len(tools) == 0 {
		return
	}

	// By the component that wants each one, which is the question somebody
	// reading this has: not "what is missing" but "what does the Kubernetes part
	// of my editor use". Stable, so within a component the contract's own order
	// survives.
	sorted := append([]detect.Tool(nil), tools...)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Component < sorted[j].Component })

	rows := make([][]string, 0, len(sorted))
	for _, tool := range sorted {
		rows = append(rows, []string{
			tool.Component,
			strings.Join(tool.Names, " or "),
			external(tool.Status),
			detail(tool),
		})
	}

	width := room(w)
	out := colour(w)
	fmt.Fprint(out, "\nExternal tools\n")
	fmt.Fprintln(out, paragraph("These belong to your system. Chroma does not install, upgrade or replace them. A feature that needs one says so when you use it.", 2, width))
	fmt.Fprintln(out)
	fmt.Fprintln(out, grid([]string{"Component", "Tool", "State", "Detail"}, rows, sorted, width))
}

// own is what a state is called when the tool is Chroma's own.
func own(status detect.Status) string {
	switch status {
	case detect.Present:
		return "ok"
	case detect.TooOld:
		return "too old"
	default:
		return "not found"
	}
}

// external is what the same state is called when the tool is the user's.
//
// `found` rather than `ok`, because `ok` is a verdict and Chroma has no standing
// to pass one on somebody else's terraform. The two words differ for the same
// reason the colours do.
func external(status detect.Status) string {
	if status == detect.Absent {
		return "not found"
	}
	return "found"
}

// detail is the sentence beside a state: what answered, or why it was wanted.
func detail(tool detect.Tool) string {
	switch tool.Status {
	case detect.Present:
		return answered(tool)
	case detect.TooOld:
		// Both halves, on two lines. A version that fails a constraint is not
		// solved by installing the package again, so the number that is there and
		// the number that is wanted have to appear together — and the reason is
		// still worth saying, because it is why the floor exists.
		return fmt.Sprintf("%s, %s\n%s", answered(tool), wanted(tool.Want), tool.Reason)
	default:
		return tool.Reason
	}
}

// answered says what replied to the lookup, and what it said it was.
func answered(tool detect.Tool) string {
	if tool.Version == "" {
		return fmt.Sprintf("%s, a version it would not report", tool.Found)
	}
	return fmt.Sprintf("%s %s", tool.Found, tool.Version)
}

// wanted puts a constraint into words.
func wanted(version *component.Version) string {
	switch {
	case version == nil:
		return "and that is enough"
	case version.Min != "" && version.Max != "":
		return version.Min + " to " + version.Max + " is required"
	case version.Min != "":
		return "at least " + version.Min + " is required"
	case version.Max != "":
		return "at most " + version.Max + " is required"
	default:
		return "and that is enough"
	}
}
