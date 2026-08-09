package main

import (
	"flag"
	"fmt"
	"os"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/detect"
	"github.com/ultherego/chroma-nvim/cli/internal/pkg"
)

// cmdDoctor reports what each component needs and what this machine has.
//
// Four answers rather than two. "Missing" sent everybody to the same place
// regardless of whether the thing could be installed with one command, had to
// be fetched by hand, or was sitting right there and too old — which is the
// question somebody actually has before deciding what to do next.
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
	if system.PackageManager != "" {
		fmt.Fprintf(out, ", %s", system.PackageManager)
	} else {
		fmt.Fprint(out, ", no package manager this knows")
	}
	if system.IsRoot {
		fmt.Fprint(out, ", running as root")
	}
	fmt.Fprint(out, "\n\n")

	// Every component this tree ships, so `doctor` answers "what would I need
	// for that" as well as "what am I missing now".
	tools := detect.Tools(loaded, loaded.IDs(), system, nil, nil)

	incomplete := false
	installable := map[string]bool{}

	for _, tool := range tools {
		names := strings.Join(tool.Names, " or ")

		switch tool.Status {
		case detect.Present:
			fmt.Fprintf(out, "ok        %-24s %s\n", names, describeVersion(tool))

		case detect.TooOld:
			incomplete = incomplete || tool.Required()
			fmt.Fprintf(out, "too old   %-24s %s is %s, %s\n",
				names, tool.Found, describe(tool.Version), want(component.Tool{Version: tool.Want}))
			fmt.Fprintf(out, "          %s — %s\n", tool.Component, tool.Reason)

		case detect.Installable:
			incomplete = incomplete || tool.Required()
			installable[tool.Package] = true
			fmt.Fprintf(out, "missing   %-24s %s — %s\n", names, tool.Level, tool.Reason)
			fmt.Fprintf(out, "          %s\n", pkg.Describe(tool.Command))

		case detect.Manual:
			incomplete = incomplete || tool.Required()
			fmt.Fprintf(out, "missing   %-24s %s — %s\n", names, tool.Level, tool.Reason)
			fmt.Fprintf(out, "          install it yourself; nothing here has a verified package for it\n")
		}
	}

	// Everything installable in one command, because that is what somebody is
	// about to assemble by hand from the lines above.
	if len(installable) > 0 {
		names := make([]string, 0, len(installable))
		for name := range installable {
			names = append(names, name)
		}
		sort.Strings(names)

		if command, ok := pkg.InstallCommand(system.PackageManager, names); ok {
			fmt.Fprintf(out, "\nAll of the installable ones:\n  %s\n", pkg.Describe(command))
		}
	}

	// Not a failure: a component nobody wants is allowed to be incomplete. The
	// exit code says "something required is missing", and the caller decides.
	if incomplete {
		return exitPreflight
	}
	return exitOK
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
