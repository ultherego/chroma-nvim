package tui

import (
	"bytes"
	"errors"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// A contract built for the occasion, so these cases do not change meaning when
// the shipped one does.
func fixture() component.Set {
	return component.Set{
		"core":       {ID: "core", Name: "Core"},
		"terraform":  {ID: "terraform", Name: "Terraform / OpenTofu", Description: "plan and apply", Requires: []string{"core"}},
		"kubernetes": {ID: "kubernetes", Name: "Kubernetes", Description: "manifests and clusters", Requires: []string{"core"}},
		"vault":      {ID: "vault", Name: "Ansible Vault", Requires: []string{"core"}},
	}
}

// answers drives one run: every line the reader would type, in order.
func answers(lines ...string) *strings.Reader {
	return strings.NewReader(strings.Join(lines, "\n") + "\n")
}

func run(t *testing.T, opts install.Options, lines ...string) (install.Options, string, error) {
	t.Helper()

	var out bytes.Buffer
	got, err := Ask(opts, fixture(), answers(lines...), &out)
	return got, out.String(), err
}

// The whole point of the package: what it produces is an Options, and it is the
// same Options the flags would have built.
func TestItProducesTheSameOptionsAsFlags(t *testing.T) {
	// Position 1 is kubernetes, 2 terraform, 3 vault — sorted, core excluded.
	got, _, err := run(t, install.Options{}, "1", "1 2", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}

	if strings.Join(got.Selected, ",") != "kubernetes,terraform" {
		t.Errorf("selected = %v, want kubernetes and terraform", got.Selected)
	}
	if got.UseDefault {
		t.Error("answering 1 chose the default location, which is not a takeover")
	}
}

func TestTakeoverIsChosenByAnsweringTwo(t *testing.T) {
	got, _, err := run(t, install.Options{}, "2", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if !got.UseDefault {
		t.Error("answering 2 did not choose the takeover")
	}
}

// Core is not offered, because it is not a choice. A checkbox that cannot be
// cleared is a worse lie than no checkbox.
func TestCoreIsNotOffered(t *testing.T) {
	_, text, err := run(t, install.Options{}, "1", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}

	for _, line := range strings.Split(text, "\n") {
		if strings.Contains(line, "[ ]") || strings.Contains(line, "[x]") {
			if strings.Contains(strings.ToLower(line), "core") {
				t.Errorf("core is offered as a choice: %q", line)
			}
		}
	}
}

// A question a flag has already answered is not asked. This is the rule that
// stops the two flows becoming two implementations.
func TestAnAnsweredQuestionIsNotAsked(t *testing.T) {
	for _, tc := range []struct {
		name string
		opts install.Options
		gone string
	}{
		{"components given", install.Options{Selected: []string{"terraform"}}, "Which parts"},
		{"core alone given", install.Options{Selected: []string{}}, "Which parts"},
		{"profile given", install.Options{Profile: "minimal"}, "Which parts"},
		{"takeover given", install.Options{UseDefault: true}, "Where should it go"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			// Enough answers for whatever is still asked, and no more.
			_, text, err := run(t, tc.opts, "1", "")
			if err != nil {
				t.Fatalf("Ask: %v", err)
			}
			if strings.Contains(text, tc.gone) {
				t.Errorf("asked %q although a flag answered it:\n%s", tc.gone, text)
			}
		})
	}
}

// An explicitly empty --components means core alone, and it must survive as an
// answer rather
// than being re-asked as though nobody had said anything.
func TestCoreAloneSurvives(t *testing.T) {
	got, _, err := run(t, install.Options{Selected: []string{}}, "1")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if got.Selected == nil {
		t.Error("an explicit empty selection became nil, which means nobody said")
	}
	if len(got.Selected) != 0 {
		t.Errorf("selected = %v, want core alone", got.Selected)
	}
}

func TestNonInteractiveAsksNothing(t *testing.T) {
	var out bytes.Buffer
	opts := install.Options{NonInteractive: true, Selected: []string{"terraform"}}

	got, err := Ask(opts, fixture(), strings.NewReader(""), &out)
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if out.Len() != 0 {
		t.Errorf("wrote %q with --non-interactive", out.String())
	}
	if strings.Join(got.Selected, ",") != "terraform" {
		t.Errorf("selected = %v, want it untouched", got.Selected)
	}
}

// Nobody to ask is a refusal, not a default. A pipe that has run out has not
// agreed to a location or to a set of components.
func TestExhaustedInputIsRefusedRatherThanDefaulted(t *testing.T) {
	var out bytes.Buffer

	_, err := Ask(install.Options{}, fixture(), strings.NewReader(""), &out)
	if !errors.Is(err, ErrNoInput) {
		t.Errorf("err = %v, want ErrNoInput: an empty pipe agreed to nothing", err)
	}
}

// And it holds after the first question too, which is where a naive reader
// would return an empty line and quietly accept every default.
func TestExhaustedInputPartWayThroughIsAlsoRefused(t *testing.T) {
	var out bytes.Buffer

	// Answers the location, then the pipe ends.
	_, err := Ask(install.Options{}, fixture(), strings.NewReader("1\n"), &out)
	if !errors.Is(err, ErrNoInput) {
		t.Errorf("err = %v, want ErrNoInput", err)
	}
}

func TestAnUnknownLocationIsAskedAgain(t *testing.T) {
	got, text, err := run(t, install.Options{}, "7", "2", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if !strings.Contains(text, `"7" is neither 1 nor 2`) {
		t.Errorf("a bad answer was not reported:\n%s", text)
	}
	if !got.UseDefault {
		t.Error("the second answer was not taken")
	}
}

// Half of a toggle list is not what anybody typed, so a line with a bad number
// applies none of itself.
func TestABadNumberLeavesTheWholeLineUnapplied(t *testing.T) {
	got, text, err := run(t, install.Options{}, "1", "1 99", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if !strings.Contains(text, `"99" is not one of the numbers`) {
		t.Errorf("the bad number was not reported:\n%s", text)
	}
	if len(got.Selected) != 0 {
		t.Errorf("selected = %v; the line had a bad number and applied anyway", got.Selected)
	}
}

// The all-or-nothing rule lives in parseNumbers, and is defended twice — it
// returns nothing, and the caller skips the line anyway. Either guard alone
// makes the behaviour right, so neither shows up as a failure when the other is
// broken; this holds the rule itself.
func TestParseNumbersIsAllOrNothing(t *testing.T) {
	for _, tc := range []struct {
		name   string
		answer string
		want   []int
		bad    string
	}{
		{"one number", "2", []int{1}, ""},
		{"spaces and commas", "1, 3", []int{0, 2}, ""},
		{"a number past the end", "1 99", nil, "99"},
		{"not a number at all", "1 x", nil, "x"},
		{"zero is not a position", "0", nil, "0"},
		{"nothing at all", "   ", nil, "   "},
	} {
		t.Run(tc.name, func(t *testing.T) {
			picked, bad := parseNumbers(tc.answer, 3)

			if bad != tc.bad {
				t.Errorf("bad = %q, want %q", bad, tc.bad)
			}
			if len(picked) != len(tc.want) {
				t.Fatalf("picked = %v, want %v — a rejected line must apply none of itself", picked, tc.want)
			}
			for i := range picked {
				if picked[i] != tc.want[i] {
					t.Errorf("picked = %v, want %v", picked, tc.want)
					break
				}
			}
		})
	}
}

func TestToggleTurnsOffAsWellAsOn(t *testing.T) {
	got, _, err := run(t, install.Options{}, "1", "2", "2", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if len(got.Selected) != 0 {
		t.Errorf("selected = %v, want nothing: the same number was typed twice", got.Selected)
	}
}

func TestAllAndNone(t *testing.T) {
	got, _, err := run(t, install.Options{}, "1", "a", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if strings.Join(got.Selected, ",") != "kubernetes,terraform,vault" {
		t.Errorf("selected = %v, want every optional component", got.Selected)
	}

	got, _, err = run(t, install.Options{}, "1", "a", "n", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}
	if len(got.Selected) != 0 {
		t.Errorf("selected = %v, want nothing after `n`", got.Selected)
	}
}

// What it produces has to be a legal request, or the interactive flow can build
// something the flag flow would have refused.
func TestWhatItProducesValidates(t *testing.T) {
	got, _, err := run(t, install.Options{}, "1", "a", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}

	if err := got.Validate(); err != nil {
		t.Errorf("the interactive flow produced options the flag flow refuses: %v", err)
	}
	if _, err := got.Selection(fixture()); err != nil {
		t.Errorf("its selection does not resolve against the contract it was built from: %v", err)
	}
}

// The names come from the contract, not from a list in here that would drift.
func TestItShowsWhatTheContractSays(t *testing.T) {
	_, text, err := run(t, install.Options{}, "1", "")
	if err != nil {
		t.Fatalf("Ask: %v", err)
	}

	for _, want := range []string{"Terraform / OpenTofu", "plan and apply", "Kubernetes", "manifests and clusters"} {
		if !strings.Contains(text, want) {
			t.Errorf("the contract's %q is not shown:\n%s", want, text)
		}
	}
}
