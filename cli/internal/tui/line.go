// This file is the line-oriented flow, and it is not a legacy path.
//
// It reads an io.Reader and writes an io.Writer, so every screen here works
// over a pipe, in a test and in CI. There is no raw mode, no cursor addressing
// and no redraw. That is what makes it the one that runs whenever there is no
// terminal to draw on — and, measured, the one that is correct there.
//
// The library that draws the terminal version has an accessible mode meant for
// exactly this, and it was tried first. Two measurements sent it back:
//
//	strings.NewReader("2\n3\n0\n")  →  only the first option was selected
//	strings.NewReader("")           →  an empty selection, and a nil error
//
// The second is the one that decided it. A closed pipe has to be a refusal —
// see ErrNoInput — and there it is silently an answer, so an installation would
// proceed on a choice nobody made. The cause is upstream and deliberate: the
// accessible prompt cannot signal an error, so end-of-input reads as the
// default, and a fresh bufio.Scanner per prompt discards whatever the previous
// one had already buffered out of the pipe.
//
// So this is not kept for compatibility. It is the correct implementation for
// everything that is not a terminal, and the terminal version is an enhancement
// on top of it.
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
)

// overLines is the adapter that asks by printing and reading lines.
func overLines(what questions, set component.Set, in io.Reader, out io.Writer) (Choices, error) {
	reader := bufio.NewReader(in)
	chosen := Choices{UseDefault: what.takenOver}

	if what.location {
		welcome(out)
		takeover, err := askLocation(reader, out)
		if err != nil {
			return Choices{}, err
		}
		chosen.UseDefault = takeover
	}

	if what.components {
		selected, err := askComponents(reader, out, set, what.current)
		if err != nil {
			return Choices{}, err
		}
		chosen.Components = selected
	}

	return chosen, nil
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
	chosen := seeded(current)

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

// seeded turns a selection into the ticks a selector starts with.
//
// Shared by both adapters, so "what is already chosen" cannot come to mean two
// different things depending on whether there is a terminal.
func seeded(current []string) map[string]bool {
	already := map[string]bool{}
	for _, id := range current {
		if id != "core" {
			already[id] = true
		}
	}
	return already
}
