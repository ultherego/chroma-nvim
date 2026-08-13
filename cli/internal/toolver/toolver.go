// Package toolver knows how to ask a tool what version it is. Deliberately not
// in the component contract: a manifest says *what* is required, which is a fact
// about the product, while how to get a version out of an executable is a fact
// about that executable and changes when it does.
package toolver

import (
	"context"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// timeout bounds one version query. These are local, fast commands; a tool that
// does not answer in a second is a tool something is wrong with, and the answer
// "unknown" is better than a hung installer. The same reasoning the rest of this
// project applies to every subprocess it waits on.
const timeout = 2 * time.Second

// Query is how to ask one tool. Args defaults to --version; Pattern defaults to
// the first dotted number in the output.
type Query struct {
	Args    []string
	Pattern *regexp.Regexp
}

var dotted = regexp.MustCompile(`\d+\.\d+(\.\d+)?`)

// registry holds the tools that do not answer to a plain --version, or whose
// output needs more than the first number in it. Everything else takes the
// default, which is most things.
var registry = map[string]Query{
	// Prints "Client Version: v1.36.3" and then Kustomize's, which the
	// first-line rule below already handles. Without --client it tries to reach
	// a cluster, which is neither fast nor the question being asked.
	"kubectl": {Args: []string{"version", "--client"}},
	// `terraform --version` works, but `version` is the documented spelling and
	// prints the same first line.
	"terraform": {Args: []string{"version"}},
	"tofu":      {Args: []string{"version"}},
	// Prints `version.BuildInfo{Version:"v3.16.2", ...}`.
	"helm": {Args: []string{"version", "--short"}},
	// The first number in `ansible [core 2.21.1]` is the one that matters, and
	// it is not first on the line in every build, so it is matched explicitly.
	"ansible":       {Args: []string{"--version"}, Pattern: regexp.MustCompile(`core\s+(\d+\.\d+(\.\d+)?)`)},
	"ansible-vault": {Args: []string{"--version"}, Pattern: regexp.MustCompile(`core\s+(\d+\.\d+(\.\d+)?)`)},
	// Info-ZIP has no --version: it prints usage, warns about the flags it was
	// given, and puts its version on the second line of that. Measured on
	// UnZip 6.00.
	"unzip": {Args: []string{"-v"}, Pattern: regexp.MustCompile(`UnZip\s+(\d+\.\d+(\.\d+)?)`)},
}

// Of returns the version of a command on PATH, or "" when it cannot be
// established. Unknown is not an error: a tool that will not say what it is can
// still be reported as present, and a constraint on it will simply not be met.
func Of(name string) string {
	query, known := registry[name]
	if !known || len(query.Args) == 0 {
		query.Args = []string{"--version"}
	}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	output, err := exec.CommandContext(ctx, name, query.Args...).CombinedOutput()
	if err != nil && len(output) == 0 {
		return ""
	}

	text := string(output)

	if query.Pattern != nil {
		if match := query.Pattern.FindStringSubmatch(text); len(match) > 1 {
			return match[1]
		}
		return ""
	}

	// The first line only: several tools print their own version and then their
	// dependencies', and the first one is theirs.
	if line, _, found := strings.Cut(text, "\n"); found {
		text = line
	}

	return dotted.FindString(text)
}
