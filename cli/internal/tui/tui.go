// Package tui asks the questions a flag did not answer.
//
// It holds no decisions. Everything it shows comes from the component contract,
// and everything it produces is an install.Options — the same value the flag
// flow builds, so `--non-interactive` is not a second implementation of
// installing. What happens after the last question is identical either way:
// build the plan, show it, confirm, and hand it to the installer.
//
// Line-oriented on purpose, and worth saying why rather than discovering later.
// It reads an io.Reader and writes an io.Writer, so every screen here is tested
// without a terminal, over a pipe, in CI. There is no raw mode, no cursor
// addressing and no redraw — which is also why the CLI still has no third-party
// dependency: the Go standard library has no terminal control, so a full-screen
// interface would be somebody else's library and their transitive tree, and
// that is the maintainer's call to make rather than a thing to arrive by
// accident inside a milestone.
package tui

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"sort"
	"strconv"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// ErrNoInput is returned when there is nobody to ask.
//
// Its own error because the alternative is worse: a closed stdin would
// otherwise read as an empty line, an empty line means "accept the default",
// and an installation would proceed on answers nobody gave.
var ErrNoInput = errors.New("nothing to read answers from; use --non-interactive with --components or --profile")

// Ask runs the interactive flow over the options a caller already has.
//
// A question whose answer is already on the command line is not asked. That is
// the rule that keeps this honest: `--components terraform` and answering
// "terraform" here have to reach the same Options, or the two flows have begun
// to differ.
func Ask(opts install.Options, set component.Set, in io.Reader, out io.Writer) (install.Options, error) {
	if opts.NonInteractive {
		return opts, nil
	}

	reader := bufio.NewReader(in)

	welcome(out)

	if !opts.UseDefault {
		takeover, err := askLocation(reader, out)
		if err != nil {
			return opts, err
		}
		opts.UseDefault = takeover
	}

	// Selected nil means nobody has said anything about components yet; empty
	// means somebody said "core alone", which is an answer and is not asked
	// again. Profile is an answer too.
	if opts.Selected == nil && opts.Profile == "" {
		selected, err := askComponents(reader, out, set, nil)
		if err != nil {
			return opts, err
		}
		opts.Selected = selected
	}

	return opts, nil
}

// Components asks which parts somebody wants, starting from the ones they have.
//
// The same screen `install` uses, called on its own by `chroma components`.
// Sharing it is the point: two selectors would be two ideas of what a component
// list looks like, and the one nobody looks at would be the one that goes wrong.
func Components(set component.Set, current []string, in io.Reader, out io.Writer) ([]string, error) {
	return askComponents(bufio.NewReader(in), out, set, current)
}

func welcome(out io.Writer) {
	fmt.Fprint(out, "\nChroma Neovim\n\n")
	fmt.Fprint(out, "  A Neovim configuration for infrastructure work. This will ask where it\n")
	fmt.Fprint(out, "  should go and which parts you want, then show you the whole plan before\n")
	fmt.Fprint(out, "  anything is written.\n")
}

// askLocation offers the two placements the installer actually supports.
func askLocation(reader *bufio.Reader, out io.Writer) (bool, error) {
	fmt.Fprint(out, "\nWhere should it go?\n\n")
	fmt.Fprint(out, "  1  ~/.config/chroma-nvim, run with NVIM_APPNAME=chroma-nvim  (default)\n")
	fmt.Fprint(out, "     Leaves your existing Neovim configuration alone.\n")
	fmt.Fprint(out, "  2  ~/.config/nvim, taking over the default configuration\n")
	fmt.Fprint(out, "     What is there now is backed up first.\n")

	for {
		answer, err := ask(reader, out, "\nChoose 1 or 2 [1]: ")
		if err != nil {
			return false, err
		}

		switch answer {
		case "", "1":
			return false, nil
		case "2":
			return true, nil
		default:
			fmt.Fprintf(out, "  %q is neither 1 nor 2.\n", answer)
		}
	}
}

// askComponents toggles a selection until the reader accepts it.
//
// Core is not in the list. It is not a choice, and offering a checkbox that
// cannot be cleared is a worse lie than not offering one.
func askComponents(reader *bufio.Reader, out io.Writer, set component.Set, current []string) ([]string, error) {
	optional := optionalIn(set)
	if len(optional) == 0 {
		return []string{}, nil
	}

	// Seeded with what is already chosen, so changing one thing means toggling
	// one number rather than retyping a selection somebody made a year ago.
	chosen := map[string]bool{}
	for _, id := range current {
		chosen[id] = true
	}

	for {
		fmt.Fprint(out, "\nWhich parts do you want?\n\n")
		fmt.Fprint(out, "  Core is always installed and is not listed.\n\n")

		for i, id := range optional {
			mark := " "
			if chosen[id] {
				mark = "x"
			}
			fmt.Fprintf(out, "  %2d  [%s]  %s\n", i+1, mark, name(set, id))
			if description := set[id].Description; description != "" {
				fmt.Fprintf(out, "          %s\n", description)
			}
		}

		fmt.Fprint(out, "\n  Numbers toggle. `a` selects all, `n` clears, empty line accepts.\n")

		answer, err := ask(reader, out, "\n> ")
		if err != nil {
			return nil, err
		}

		switch strings.ToLower(answer) {
		case "":
			return selectionOf(chosen), nil
		case "a":
			for _, id := range optional {
				chosen[id] = true
			}
			continue
		case "n":
			chosen = map[string]bool{}
			continue
		}

		// A bad number leaves the whole line unapplied rather than applying the
		// part that parsed: half of a toggle list is not what anybody typed.
		picked, bad := parseNumbers(answer, len(optional))
		if bad != "" {
			fmt.Fprintf(out, "  %q is not one of the numbers above.\n", bad)
			continue
		}
		for _, at := range picked {
			id := optional[at]
			chosen[id] = !chosen[id]
		}
	}
}

// parseNumbers reads a line of positions, and reports the first that is not one.
func parseNumbers(answer string, count int) ([]int, string) {
	fields := strings.FieldsFunc(answer, func(r rune) bool {
		return r == ' ' || r == ',' || r == '\t'
	})

	var picked []int
	for _, field := range fields {
		number, err := strconv.Atoi(field)
		if err != nil || number < 1 || number > count {
			return nil, field
		}
		picked = append(picked, number-1)
	}
	if len(picked) == 0 {
		return nil, answer
	}
	return picked, ""
}

// optionalIn is every component that is a choice, in a stable order.
func optionalIn(set component.Set) []string {
	var ids []string
	for _, id := range set.IDs() {
		if id != "core" {
			ids = append(ids, id)
		}
	}
	sort.Strings(ids)
	return ids
}

func name(set component.Set, id string) string {
	if one := set[id]; one != nil && one.Name != "" {
		return one.Name
	}
	return id
}

func selectionOf(chosen map[string]bool) []string {
	selected := []string{}
	for id, yes := range chosen {
		if yes {
			selected = append(selected, id)
		}
	}
	sort.Strings(selected)
	return selected
}

// ask prints a prompt and reads one line.
//
// io.EOF is a refusal, not an empty answer. A pipe that has run out has not
// agreed to anything, and the difference decides whether an installation
// proceeds on defaults nobody chose.
func ask(reader *bufio.Reader, out io.Writer, prompt string) (string, error) {
	fmt.Fprint(out, prompt)

	line, err := reader.ReadString('\n')
	if err != nil {
		if errors.Is(err, io.EOF) && strings.TrimSpace(line) != "" {
			// A last line with no newline is still an answer.
			return strings.TrimSpace(line), nil
		}
		if errors.Is(err, io.EOF) {
			return "", ErrNoInput
		}
		return "", err
	}

	return strings.TrimSpace(line), nil
}
