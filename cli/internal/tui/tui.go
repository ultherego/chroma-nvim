// Package tui asks the questions a flag did not answer, and holds no decisions:
// everything it shows comes from the component contract, and everything it
// produces is a Choices, which one function turns into install.Options. What
// happens after the last question is identical either way.
//
// **This package never performs an installation.** It returns values.
//
// Two ways of asking and one meaning: full-screen selectors on a terminal,
// printed questions over a pipe or under `--plain`, and nothing at all under
// `--non-interactive`. The two adapters are input adapters rather than two
// definitions of what an answer means — a test drives the same questions through
// both and compares.
package tui

import (
	"errors"
	"io"
	"os"
	"sort"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// ErrNoInput is returned when there is nobody to ask. Its own error because a
// closed stdin would otherwise read as an empty line, an empty line means
// "accept the default", and an installation would proceed on answers nobody gave.
var ErrNoInput = errors.New("nothing to read answers from; use --non-interactive with --components or --profile")

// ErrAborted is somebody pressing escape, or interrupting. Different from
// ErrNoInput on purpose: one is a machine with nothing to say, the other a
// person who has decided not to.
var ErrAborted = errors.New("nothing was chosen")

// Choices is what a person decided, and nothing else.
//
// Neither adapter builds an install.Options. They fill this in, and `apply`
// turns it into options — so "what the answers mean" is written once and the
// two ways of collecting them cannot drift apart in meaning, only in
// appearance.
type Choices struct {
	// UseDefault is the placement: take over Neovim's own directories, or live
	// beside them.
	UseDefault bool

	// Components is the optional components chosen, without core. Nil means the
	// question was not put; empty means it was, and the answer was none of
	// them. The difference decides whether a later step asks again.
	Components []string
}

// questions is what still needs asking after the flags have been read.
type questions struct {
	location   bool
	components bool

	// takenOver carries the placement through when it was already decided by a
	// flag, so an adapter that is only asking about components still returns a
	// complete Choices.
	takenOver bool

	// current seeds the component selector with what is already chosen, so
	// changing one thing means moving one checkbox rather than restating a
	// selection somebody made a year ago.
	current []string
}

// adapter is one way of putting questions to a person.
type adapter func(what questions, set component.Set, in io.Reader, out io.Writer) (Choices, error)

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

	what := questions{
		location:  !opts.UseDefault,
		takenOver: opts.UseDefault,

		// Selected nil means nobody has said anything about components yet;
		// empty means somebody said "core alone", which is an answer and is not
		// asked again. Profile is an answer too.
		components: opts.Selected == nil && opts.Profile == "",
	}
	if !what.location && !what.components {
		return opts, nil
	}

	chosen, err := asking(in, out, opts.Plain)(what, set, in, out)
	if err != nil {
		return opts, err
	}
	return apply(opts, chosen), nil
}

// Components asks which parts somebody wants, starting from the ones they have.
//
// The same screen `install` uses, called on its own by `chroma components`.
// Sharing it is the point: two selectors would be two ideas of what a component
// list looks like, and the one nobody looks at would be the one that goes wrong.
func Components(set component.Set, current []string, plain bool, in io.Reader, out io.Writer) ([]string, error) {
	chosen, err := asking(in, out, plain)(questions{components: true, current: current}, set, in, out)
	if err != nil {
		return nil, err
	}
	return chosen.Components, nil
}

// apply is what the answers mean, written once.
func apply(opts install.Options, chosen Choices) install.Options {
	opts.UseDefault = chosen.UseDefault
	if chosen.Components != nil {
		selected := append([]string{}, chosen.Components...)
		sort.Strings(selected)
		opts.Selected = selected
	}
	return opts
}

// asking picks the adapter for what is at both ends, and both is the invariant:
// a screen UI needs a terminal to draw on and a terminal to take keys from.
//
//	chroma install > install.log    the plan would be drawn into a file
//	echo | chroma install           there are no arrow keys in a pipe
//
// A pipe, a file and a test's temporary file are all "not a terminal" and all
// get the printed questions — which is also the answer for a screen reader.
//
// `--plain` or CHROMA_PLAIN asks for those on a terminal too. It is not a switch
// between two installers: everything after the last answer is the same code.
func asking(in io.Reader, out io.Writer, plain bool) adapter {
	if plain || plainly() {
		return overLines
	}
	if isTerminal(in) && isTerminal(out) {
		return onScreen
	}
	return overLines
}

// plainly reports whether the environment asks for the printed questions. Set to
// anything but empty or `0`, so `=1`, `=true` and `=yes` all work. An
// environment variable as well as a flag, because a dotfile, a CI job and a
// `sudo -E` can set it once instead of remembering the flag.
func plainly() bool {
	switch os.Getenv("CHROMA_PLAIN") {
	case "", "0":
		return false
	default:
		return true
	}
}

// isTerminal is the predicate below, in a variable. A test cannot hand this
// package a real terminal, so without a seam the only case it could check is
// "neither end is one" — which passes whether the rule asks about one end or
// both. Measured: a mutant that went back to asking only about the output
// survived the whole suite until this existed.
var isTerminal = terminal

// terminal reports whether something is a character device — a terminal — as
// opposed to a pipe, a file, or anything else that merely carries bytes.
func terminal(end any) bool {
	file, ok := end.(*os.File)
	if !ok {
		return false
	}
	info, err := file.Stat()
	return err == nil && info.Mode()&os.ModeCharDevice != 0
}
