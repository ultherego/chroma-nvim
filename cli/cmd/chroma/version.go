package main

import (
	"fmt"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

func cmdVersion(out *os.File) int {
	shown := version
	if shown == "" {
		shown = "(built from source)"
	}
	fmt.Fprintf(out, "chroma %s\ncomponent contract %d\n", shown, component.Contract)
	return exitOK
}
