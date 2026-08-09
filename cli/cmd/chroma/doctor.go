package main

import (
	"flag"
	"fmt"
	"os"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/toolver"
)

func cmdDoctor(args []string, out, errOut *os.File) int {
	dir, code := tree(flag.NewFlagSet("doctor", flag.ContinueOnError), args, errOut)
	if code != exitOK {
		return code
	}

	set, code := load(dir, errOut)
	if code != exitOK {
		return code
	}

	incomplete := false
	for _, id := range set.IDs() {
		one := set[id]
		unsatisfied := one.Unsatisfied(onPath, toolver.Of)
		if len(unsatisfied) == 0 {
			fmt.Fprintf(out, "ok      %-16s %s\n", one.ID, one.Name)
			continue
		}

		incomplete = true
		fmt.Fprintf(out, "missing %-16s %s\n", one.ID, one.Name)
		for _, tool := range unsatisfied {
			names := strings.Join(tool.Names(), " or ")

			// Present but too old reads nothing like absent, and saying "missing"
			// for it would send somebody looking for a package they already have.
			if found, version := firstPresent(tool); found != "" {
				fmt.Fprintf(out, "          %s is %s, %s — %s\n", found, describe(version), want(tool), tool.Reason)
				continue
			}
			fmt.Fprintf(out, "          %s not found — %s\n", names, tool.Reason)
		}
	}

	// Not a failure: a component nobody wants is allowed to be incomplete. The
	// exit code says "something is missing", and the caller decides.
	if incomplete {
		return exitPreflight
	}
	return exitOK
}

// firstPresent returns the first of a tool's names that exists, and its version.
func firstPresent(tool component.Tool) (string, string) {
	for _, name := range tool.Names() {
		if onPath(name) {
			return name, toolver.Of(name)
		}
	}
	return "", ""
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
