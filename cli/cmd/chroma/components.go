package main

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

func cmdComponents(args []string, out, errOut *os.File) int {
	dir, code := tree(flag.NewFlagSet("components", flag.ContinueOnError), args, errOut)
	if code != exitOK {
		return code
	}

	set, code := load(dir, errOut)
	if code != exitOK {
		return code
	}

	for _, id := range set.IDs() {
		one := set[id]
		requires := ""
		if len(one.Requires) > 0 {
			requires = "requires " + strings.Join(one.Requires, ", ")
		}
		fmt.Fprintf(out, "%-16s %-24s %s\n", one.ID, one.Name, requires)
	}
	return exitOK
}
