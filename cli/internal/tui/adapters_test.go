package tui

import (
	"errors"
	"io"
	"os"
	"reflect"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// contract is the one this repository ships, which is what both adapters show.
func contract(t *testing.T) component.Set {
	t.Helper()

	set, problems, err := component.Load("../../../components")
	if err != nil || len(problems) > 0 {
		t.Fatalf("Load: %v %v", err, problems)
	}
	return set
}

// The two adapters are two ways of asking, not two ideas of what is on offer.
//
// This is the test that keeps them from becoming audit finding 11 in a new
// place: there, a plan and a report each decided for themselves whether a tool
// was usable, and they disagreed about the same machine. Here they must offer
// the same components, in the same order, with the same ones already ticked.
func TestBothAdaptersOfferTheSameComponents(t *testing.T) {
	set := contract(t)
	current := []string{"terraform", "kubernetes"}

	// What the terminal one puts on the screen.
	var ids, labels []string
	for _, one := range componentOptions(set, optionalIn(set), seeded(current)) {
		ids = append(ids, one.Value)
		labels = append(labels, one.Key)
	}
	if !reflect.DeepEqual(ids, optionalIn(set)) {
		t.Errorf("the selector offers %v, the list of optional components is %v", ids, optionalIn(set))
	}

	// What the line-oriented one prints, read back out of its own output.
	out, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	if _, err := overLines(questions{components: true, current: current}, set, strings.NewReader("\n"), out); err != nil {
		t.Fatal(err)
	}
	printed, err := os.ReadFile(out.Name())
	if err != nil {
		t.Fatal(err)
	}

	for _, id := range optionalIn(set) {
		if !strings.Contains(string(printed), name(set, id)) {
			t.Errorf("the printed list does not offer %s", id)
		}
	}
	for _, id := range ids {
		if id == "core" {
			t.Error("the selector offers core, and it is not a choice")
		}
	}
	if strings.Contains(string(printed), "]  "+name(set, "core")) {
		t.Error("the printed list offers core, and it is not a choice")
	}
	_ = labels
}

// And both start from what is already chosen, or `chroma components` would ask
// somebody to restate a selection they made a year ago.
func TestBothAdaptersStartFromWhatIsAlreadyChosen(t *testing.T) {
	set := contract(t)
	current := []string{"terraform"}

	if got := seeded(current); !got["terraform"] || len(got) != 1 {
		t.Errorf("the selector starts from %v, want terraform alone", got)
	}

	out, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()
	if _, err := overLines(questions{components: true, current: current}, set, strings.NewReader("\n"), out); err != nil {
		t.Fatal(err)
	}
	printed, err := os.ReadFile(out.Name())
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(printed), "[x]  "+name(set, "terraform")) {
		t.Errorf("the printed list does not start with terraform ticked:\n%s", printed)
	}
}

// Meaning is decided once, in apply, and neither adapter builds options of its
// own. Nil components means the question was never put and whatever the flags
// said stands.
func TestApplyIsTheOnlyPlaceAnAnswerBecomesAnOption(t *testing.T) {
	base := install.Options{Selected: []string{"vault"}}

	if got := apply(base, Choices{UseDefault: true}); !reflect.DeepEqual(got.Selected, []string{"vault"}) {
		t.Errorf("an unasked question changed the selection to %v", got.Selected)
	}
	if got := apply(base, Choices{Components: []string{}}); len(got.Selected) != 0 || got.Selected == nil {
		t.Errorf("choosing nothing gave %#v, want an empty selection that is not nil", got.Selected)
	}
	if got := apply(base, Choices{Components: []string{"terraform", "aws"}}); !reflect.DeepEqual(got.Selected, []string{"aws", "terraform"}) {
		t.Errorf("selection = %v, want it sorted", got.Selected)
	}
}

// A screen UI needs a terminal at both ends, and this names both mistakes it
// prevents.
func TestTheScreenUINeedsATerminalAtBothEnds(t *testing.T) {
	file, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	// Nothing here is a terminal, so every combination has to choose the
	// printed questions. The last is the one that used to be wrong: a terminal
	// to draw on, and something that is not one to read from.
	for _, tc := range []struct {
		name string
		in   io.Reader
		out  io.Writer
	}{
		{"a pipe both ways", strings.NewReader(""), nopWriter{}},
		{"redirected output — chroma install > install.log", strings.NewReader(""), file},
		{"something that is not a terminal to read from", file, nopWriter{}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if !isOverLines(asking(tc.in, tc.out, false)) {
				t.Error("a screen UI was chosen without a terminal at both ends")
			}
		})
	}

	// The case no fixture can be: a real terminal to draw on, and something
	// that is not one to read from. Both ends have to be asked about, and a
	// stub is the only way to prove the rule does.
	for _, tc := range []struct {
		name        string
		inIs, outIs bool
		wantScreen  bool
	}{
		{"both are terminals", true, true, true},
		{"a terminal to draw on, a pipe to read from", false, true, false},
		{"a terminal to read from, a file to draw into", true, false, false},
		{"neither", false, false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			reader, writer := strings.NewReader(""), nopWriter{}
			real := isTerminal
			isTerminal = func(end any) bool {
				if end == any(reader) {
					return tc.inIs
				}
				return tc.outIs
			}
			t.Cleanup(func() { isTerminal = real })

			if got := !isOverLines(asking(reader, writer, false)); got != tc.wantScreen {
				t.Errorf("screen UI = %v, want %v", got, tc.wantScreen)
			}
		})
	}

	if terminal(file) {
		t.Error("a temporary file was taken for a terminal")
	}
	if terminal(nopWriter{}) {
		t.Error("a plain io.Writer was taken for a terminal")
	}

	// And what that decides: a closed pipe is a refusal, which is the property
	// the terminal library was measured not to have.
	if _, err := Ask(install.Options{}, contract(t), strings.NewReader(""), file); !errors.Is(err, ErrNoInput) {
		t.Errorf("a closed pipe gave %v, want ErrNoInput", err)
	}
}

// The escape hatch, on the one machine where it matters: a terminal at both
// ends, where the selectors are what would otherwise be chosen.
//
// It is checked against a stubbed terminal for the same reason the rule above
// is. Without one every case here is "not a terminal anyway", and a gate that
// did nothing at all would pass.
func TestAskingPlainlyIsHonouredWhereThereIsATerminal(t *testing.T) {
	for _, tc := range []struct {
		name       string
		flag       bool
		environ    string
		wantScreen bool
	}{
		{name: "nothing said, and a terminal at both ends", wantScreen: true},
		{name: "--plain", flag: true},
		{name: "CHROMA_PLAIN=1", environ: "1"},
		{name: "CHROMA_PLAIN=yes", environ: "yes"},
		{name: "CHROMA_PLAIN=0 is not a way of asking for it", environ: "0", wantScreen: true},
		{name: "CHROMA_PLAIN= is not either", environ: "", wantScreen: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			t.Setenv("CHROMA_PLAIN", tc.environ)

			real := isTerminal
			isTerminal = func(any) bool { return true }
			t.Cleanup(func() { isTerminal = real })

			if got := !isOverLines(asking(strings.NewReader(""), nopWriter{}, tc.flag)); got != tc.wantScreen {
				t.Errorf("screen UI = %v, want %v", got, tc.wantScreen)
			}
		})
	}
}

// The form has to have a way out, and the library's own keymap gives it one
// key with no help text. Measured before this: escape on the placement selector
// did nothing at all and the run had to be killed.
//
// A keymap is all that can be checked without a terminal, so this checks the
// keymap. What happens when the key is pressed is measured by hand, in a real
// one.
func TestTheFormCanBeLeftWithEscape(t *testing.T) {
	keys := wayOut().Quit.Keys()

	for _, want := range []string{"esc", "ctrl+c"} {
		found := false
		for _, got := range keys {
			found = found || got == want
		}
		if !found {
			t.Errorf("%q does not leave the form; it answers to %v", want, keys)
		}
	}
}

type nopWriter struct{}

func (nopWriter) Write(p []byte) (int, error) { return len(p), nil }

func isOverLines(a adapter) bool {
	return reflect.ValueOf(a).Pointer() == reflect.ValueOf(overLines).Pointer()
}
