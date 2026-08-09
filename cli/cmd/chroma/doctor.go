package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
)

// cmdDoctor reports what is on this machine. It is a diagnostic, not a gate.
//
// The report has two halves and the line between them is the point. Chroma's
// own tooling is the half that can be broken: without git there are no plugins.
// Everything else — terraform, kubectl, helm, ansible, aws, docker — belongs to
// the person running this, and its absence is reported as a fact about the
// machine rather than as a fault in the installation. So a missing kubectl
// prints `not found`, not `ERROR`, and does not change the exit code.
func cmdDoctor(args []string, out, errOut *os.File) int {
	set := flag.NewFlagSet("doctor", flag.ContinueOnError)
	dir, code := tree(set, args, errOut)
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

	// Every component this tree ships, so `doctor` answers "what would I need
	// for that" as well as "what am I missing now".
	tools := detect.Tools(loaded, loaded.IDs(), nil, nil)

	own, external := detect.Split(tools)

	broken := reportOwn(out, own)
	detect.RenderExternal(out, external)

	if broken {
		return exitPreflight
	}
	return exitOK
}

// reportOwn prints Chroma's own tooling and says whether any of it is missing.
func reportOwn(out *os.File, tools []detect.Tool) bool {
	if len(tools) == 0 {
		return false
	}

	fmt.Fprint(out, "\nChroma\n")

	broken := false
	for _, tool := range tools {
		names := strings.Join(tool.Names, " or ")

		switch tool.Status {
		case detect.Present:
			fmt.Fprintf(out, "  ok         %-24s %s\n", names, describeVersion(tool))

		case detect.TooOld:
			broken = broken || tool.Blocking()
			fmt.Fprintf(out, "  too old    %-24s %s is %s, %s\n",
				names, tool.Found, describe(tool.Version), want(component.Tool{Version: tool.Want}))
			fmt.Fprintf(out, "             %s\n", tool.Reason)

		case detect.Absent:
			broken = broken || tool.Blocking()
			fmt.Fprintf(out, "  not found  %-24s %s — %s\n", names, tool.Level, tool.Reason)
		}
	}

	return broken
}

// describeVersion says what answered, and what it said.
func describeVersion(tool detect.Tool) string {
	if tool.Version == "" {
		return tool.Found
	}
	return fmt.Sprintf("%s %s", tool.Found, tool.Version)
}

func describe(version string) string {
	if version == "" {
		return "a version it would not report"
	}
	return version
}

func want(tool component.Tool) string {
	v := tool.Version
	switch {
	case v == nil:
		return "and that is enough"
	case v.Exact != "":
		return "and exactly " + v.Exact + " is required"
	case v.Min != "" && v.Max != "":
		return "and " + v.Min + " to " + v.Max + " is required"
	case v.Min != "":
		return "and at least " + v.Min + " is required"
	case v.Max != "":
		return "and at most " + v.Max + " is required"
	default:
		return "and that is enough"
	}
}
