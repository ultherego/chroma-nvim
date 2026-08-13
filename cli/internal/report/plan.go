package report

import (
	"fmt"
	"io"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// Plan prints what would happen, before anything does: what is enabled, what
// that pulled in, the state of everything Chroma needs, and a note about the
// tools that belong to the user. The same four things for an install, a dry run,
// a change of components, an update or a rollback.
func Plan(w io.Writer, p plan.Plan) {
	// The label is sixteen columns in every command that prints one of these,
	// and the continuation of a line too long for the screen lines up under it.
	const (
		label = "  Components    "
		blank = "                "
	)

	width := room(w)
	out := colour(w)

	if len(p.Unknown) > 0 {
		fmt.Fprintf(out, "%s\n\n", paragraph("Unknown components: "+strings.Join(p.Unknown, ", "), 0, width))
	}

	if len(p.Components) == 0 {
		// Saying "nothing is missing" about a plan that would install nothing is
		// technically true and completely misleading.
		under(out, label, "none — nothing would be installed", width)
		return
	}

	under(out, label, strings.Join(p.Components, ", "), width)
	if len(p.Added) > 0 {
		under(out, blank, strings.Join(p.Added, ", ")+" pulled in as a dependency", width)
	}

	// Chroma's own tooling: the half of this that can stop an installation. All
	// of it, present and missing together, because a table with one row per tool
	// answers "is my machine ready" in a way that two comma-separated lists of
	// names never did.
	if mine, _ := detect.Split(p.Tools); len(mine) > 0 {
		fmt.Fprintln(out)
		Requirements(w, mine)
	}

	// The user's own tools, named but not counted. A table of them here would
	// read as a checklist to satisfy before installing, which is exactly what it
	// is not — so this says how many and leaves the full report to the end of the
	// installation, where it is a note about the machine rather than a gate.
	if absent := absentExternal(p); len(absent) > 0 {
		fmt.Fprintln(out)
		under(out, "  External      ", strings.Join(absent, ", ")+
			" not on PATH; Chroma does not install these, and installing without them changes nothing here", width)
	}
}

// absentExternal names the user's own tools that are not on PATH.
func absentExternal(p plan.Plan) []string {
	var out []string
	for _, tool := range p.External() {
		if tool.Status != detect.Present {
			out = append(out, strings.Join(tool.Names, "/"))
		}
	}
	return out
}
