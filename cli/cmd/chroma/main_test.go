package main

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/tui"
)

// usageText captures what `chroma --help` prints.
func usageText(t *testing.T) string {
	t.Helper()

	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan string, 1)
	go func() {
		var out strings.Builder
		scanner := bufio.NewScanner(read)
		for scanner.Scan() {
			out.WriteString(scanner.Text())
			out.WriteString("\n")
		}
		done <- out.String()
	}()

	usage(write)
	write.Close()
	return <-done
}

// advertised are the command names the usage text lists, taken from the two
// indented columns it prints them in.
func advertised(t *testing.T) []string {
	t.Helper()

	var names []string
	for _, line := range strings.Split(usageText(t), "\n") {
		if !strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "   ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		// Skip the trailing prose, which is not indented like a command row.
		if strings.Contains(line, "not implemented yet") {
			names = append(names, fields[0])
			continue
		}
		names = append(names, fields[0])
	}
	return names
}

// The gap this exists for: `rollback` was written, built, vetted and unit
// tested, and still reached nobody — the only thing between it and the user was
// a `case` nobody had added, and dispatch as control flow gave no test anything
// to look at. It is a table now, and this is the check.
func TestEveryAdvertisedCommandIsReachable(t *testing.T) {
	names := advertised(t)
	if len(names) < 5 {
		t.Fatalf("the usage text listed %d commands, which cannot be right: %v", len(names), names)
	}

	for _, name := range names {
		if commands[name] != nil {
			continue
		}
		if unfinished[name] {
			continue
		}
		t.Errorf("%q is offered in the usage text and dispatches nowhere", name)
	}
}

// And the other direction: something that dispatches but is never mentioned is
// a command nobody can find.
func TestEveryCommandIsAdvertised(t *testing.T) {
	listed := map[string]bool{}
	for _, name := range advertised(t) {
		listed[name] = true
	}

	for name := range commands {
		if !listed[name] {
			t.Errorf("%q dispatches and is not in the usage text", name)
		}
	}
}

// A flag that reaches nothing is the same failure as a command that dispatches
// nowhere: it parses, it is documented, and it changes nothing.
//
// `--plain` is the escape hatch from the selector layer, so what matters is
// that the answer arrives where the adapter is chosen. This drives the real
// command up to that boundary and reads what it was handed.
func TestPlainReachesTheLayerThatAsks(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want bool
	}{
		{name: "nothing said", args: []string{"install"}},
		{name: "--plain", args: []string{"install", "--plain"}, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			empty(t)

			var asked *install.Options

			// Answered with a refusal, so the run stops at the question: this is
			// about the flag arriving, and installing anything to find that out
			// would be a different test on a real machine.
			real := askInteractively
			askInteractively = func(opts install.Options, _ component.Set, _ io.Reader, _ io.Writer) (install.Options, error) {
				asked = &opts
				return opts, tui.ErrAborted
			}
			t.Cleanup(func() { askInteractively = real })

			args := append(append([]string{}, tc.args...), "--source-tree", filepath.Join("..", "..", ".."))
			say(t, func(out, errOut *os.File) int { return run(args, out, errOut) })

			if asked == nil {
				t.Fatal("the command never reached the layer that asks")
			}
			if asked.Plain != tc.want {
				t.Errorf("Plain = %v, want %v", asked.Plain, tc.want)
			}
		})
	}
}

// And the same for the other command that asks. Two flags of the same name are
// two chances for one of them to be parsed and dropped.
func TestPlainReachesTheComponentSelector(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		want bool
	}{
		{name: "nothing said", args: []string{"components"}},
		{name: "--plain", args: []string{"components", "--plain"}, want: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			paths := machine(t)
			contractInto(t, paths.ConfigDir)

			// The selection document an installation leaves behind. Without it
			// the command stops before it would ask, which is correct and is not
			// what this measures.
			if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(paths.SelectionFile, []byte(`{"schema":1,"selected":["terraform"]}`), 0o644); err != nil {
				t.Fatal(err)
			}

			asked := false
			plain := false

			real := askComponentsInteractively
			askComponentsInteractively = func(_ component.Set, _ []string, isPlain bool, _ io.Reader, _ io.Writer) ([]string, error) {
				asked, plain = true, isPlain
				return nil, tui.ErrAborted
			}
			t.Cleanup(func() { askComponentsInteractively = real })

			printed, _ := say(t, func(out, errOut *os.File) int { return run(tc.args, out, errOut) })

			if !asked {
				t.Fatalf("the command never reached the selector:\n%s", printed)
			}
			if plain != tc.want {
				t.Errorf("plain = %v, want %v", plain, tc.want)
			}
		})
	}
}

// Escape is an answer, and a closed pipe is not.
//
// Both used to exit 2, so a person who changed their mind was told they had
// misused the CLI — while the same decision made one screen later, at
// `Proceed? [y/N]`, exited 3 and said "Nothing was changed." The exit code is
// the part of this that ends up in somebody's script, so it has to mean the
// same thing whenever the answer is given.
func TestEscapeIsADecisionAndAClosedPipeIsAMistake(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want int
		says string
	}{
		{name: "escape", err: tui.ErrAborted, want: exitDeclined, says: "Nothing was changed."},
		{name: "a closed pipe", err: tui.ErrNoInput, want: exitMisuse, says: "--non-interactive"},
	} {
		t.Run("install, "+tc.name, func(t *testing.T) {
			empty(t)

			real := askInteractively
			askInteractively = func(opts install.Options, _ component.Set, _ io.Reader, _ io.Writer) (install.Options, error) {
				return opts, tc.err
			}
			t.Cleanup(func() { askInteractively = real })

			printed, code := say(t, func(out, errOut *os.File) int {
				return run([]string{"install", "--source-tree", filepath.Join("..", "..", "..")}, out, errOut)
			})

			if code != tc.want {
				t.Errorf("exit = %d, want %d:\n%s", code, tc.want, printed)
			}
			if !strings.Contains(printed, tc.says) {
				t.Errorf("it does not say %q:\n%s", tc.says, printed)
			}
		})

		t.Run("components, "+tc.name, func(t *testing.T) {
			paths := machine(t)
			contractInto(t, paths.ConfigDir)
			if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(paths.SelectionFile, []byte(`{"schema":1,"selected":["terraform"]}`), 0o644); err != nil {
				t.Fatal(err)
			}

			real := askComponentsInteractively
			askComponentsInteractively = func(_ component.Set, _ []string, _ bool, _ io.Reader, _ io.Writer) ([]string, error) {
				return nil, tc.err
			}
			t.Cleanup(func() { askComponentsInteractively = real })

			printed, code := say(t, func(out, errOut *os.File) int {
				return run([]string{"components"}, out, errOut)
			})

			if code != tc.want {
				t.Errorf("exit = %d, want %d:\n%s", code, tc.want, printed)
			}
			if !strings.Contains(printed, tc.says) {
				t.Errorf("it does not say %q:\n%s", tc.says, printed)
			}
		})
	}
}

// A command that is not finished must say so rather than being reported as
// unknown, which would read as a typo.
func TestAnUnfinishedCommandSaysSo(t *testing.T) {
	for name := range unfinished {
		if commands[name] != nil {
			t.Errorf("%q is listed as unfinished and also dispatches", name)
		}
	}
}
