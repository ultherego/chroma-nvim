package install

import (
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/theme"
)

func TestOptionsRefuseContradictoryRequests(t *testing.T) {
	for _, tc := range []struct {
		name    string
		options Options
		mention string
	}{
		{
			name:    "a profile and a component list",
			options: Options{Profile: "minimal", Selected: []string{"terraform"}},
			mention: "use one",
		},
		{
			name:    "a version and a source tree",
			options: Options{Version: "v1.0.0", SourceTree: "/tmp/tree"},
			mention: "use one",
		},
		{
			// core is always installed, so naming it is a file written against
			// a different idea of what this flag means — refused rather than
			// quietly dropped, the same rule the selection document keeps.
			name:    "core in the component list",
			options: Options{Selected: []string{"terraform", "core"}},
			mention: `"core"`,
		},
		{
			name:    "the same component twice",
			options: Options{Selected: []string{"aws", "aws"}},
			mention: "twice",
		},
		{
			name:    "an empty component id",
			options: Options{Selected: []string{"terraform", "  "}},
			mention: "empty component id",
		},
		{
			// Nothing to fall back on: "install nothing optional" is an answer
			// somebody gives, not one to assume for them.
			name:    "non-interactive with no selection at all",
			options: Options{NonInteractive: true},
			mention: "--non-interactive needs",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := tc.options.Validate()
			if err == nil {
				t.Fatal("accepted a request that contradicts itself")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to mention %q", err, tc.mention)
			}
		})
	}
}

// Empty is an answer and nil is a silence — the same distinction the selection
// document makes between `[]` and no file at all.
func TestAnExplicitlyEmptySelectionIsAnAnswer(t *testing.T) {
	options := Options{NonInteractive: true, Selected: []string{}}
	if err := options.Validate(); err != nil {
		t.Fatalf("refused an explicit core-only selection: %v", err)
	}

	selected, err := options.Selection(shipped(t))
	if err != nil {
		t.Fatalf("Selection: %v", err)
	}
	if len(selected) != 0 {
		t.Errorf("selected = %v, want nothing optional", selected)
	}
}

func TestSelectionIsSortedAndCheckedAgainstTheContract(t *testing.T) {
	set := shipped(t)

	selected, err := Options{Selected: []string{"vault", "aws", "terraform"}}.Selection(set)
	if err != nil {
		t.Fatalf("Selection: %v", err)
	}
	if strings.Join(selected, ",") != "aws,terraform,vault" {
		t.Errorf("selected = %v, want them sorted", selected)
	}

	if _, err := (Options{Selected: []string{"magic"}}).Selection(set); err == nil {
		t.Error("accepted a component this release does not have")
	}
}

func TestProfilesResolveAgainstTheContract(t *testing.T) {
	set := shipped(t)

	for _, name := range ProfileNames() {
		selected, err := ResolveProfile(name, set)
		if err != nil {
			t.Fatalf("profile %q: %v", name, err)
		}
		// Every profile is a set of optional components, checked against the
		// contract it will be installed with — a profile naming something that
		// no longer exists has to be loud, not quietly smaller.
		for _, id := range selected {
			if id == coreID {
				t.Errorf("profile %q names core, which is not a choice", name)
			}
			if set[id] == nil {
				t.Errorf("profile %q names %q, which this release does not have", name, id)
			}
		}
	}

	if selected, err := ResolveProfile("minimal", set); err != nil || len(selected) != 0 {
		t.Errorf("minimal = %v, %v; want nothing optional", selected, err)
	}

	// everything comes from the contract rather than from a list, so it cannot
	// fall behind a component added later.
	everything, err := ResolveProfile("everything", set)
	if err != nil {
		t.Fatalf("everything: %v", err)
	}
	if len(everything) != len(set)-1 {
		t.Errorf("everything selects %d of %d components", len(everything), len(set)-1)
	}

	if _, err := ResolveProfile("terrafrom", set); err == nil {
		t.Error("accepted a profile that does not exist")
	}
}

// A profile written by hand goes stale when the contract moves. It has to fail
// loudly, because the alternative is an installation quietly containing less
// than the profile promised.
func TestAProfileNamingAMissingComponentIsRefused(t *testing.T) {
	set := shipped(t)
	delete(set, "vault")

	_, err := ResolveProfile("terraform", set)
	if err == nil {
		t.Fatal("accepted a profile naming a component this release does not have")
	}
	if !strings.Contains(err.Error(), "vault") {
		t.Errorf("err = %v, want it to name the missing component", err)
	}
}

// The theme rule is deliberately not the components rule, and this is the
// difference: `--non-interactive` without `--components` is misuse because
// there is nothing to fall back on, and here there is — the release names its
// own default. Requiring a flag would break every existing scripted install to
// no purpose.
func TestNonInteractiveNeedsNoTheme(t *testing.T) {
	opts := Options{NonInteractive: true, Selected: []string{}}

	if err := opts.Validate(); err != nil {
		t.Fatalf("a scripted install that says nothing about the colourscheme was refused: %v", err)
	}

	catalogue := offered(t, prepared(t).Root)
	got, err := opts.ThemeChoice(catalogue)
	if err != nil {
		t.Fatalf("ThemeChoice: %v", err)
	}
	if got != catalogue.Default {
		t.Errorf("theme = %q, want the release's default %q", got, catalogue.Default)
	}
}

// Whitespace and nothing else is misuse: somebody meant to name a theme.
func TestAThemeOfNothingButSpacesIsMisuse(t *testing.T) {
	if err := (Options{Theme: "   "}).Validate(); err == nil {
		t.Error("accepted --theme with nothing in it")
	}
	if err := (Options{Theme: " first "}).Validate(); err != nil {
		t.Errorf("refused a theme with a space around it: %v", err)
	}
}

func TestThemeChoiceIsCheckedAgainstTheRelease(t *testing.T) {
	catalogue := offered(t, prepared(t).Root)

	for _, tc := range []struct {
		name  string
		theme string
		want  string
		fails bool
	}{
		{name: "nothing said is the release's default", want: catalogue.Default},
		{name: "one it offers", theme: "second", want: "second"},
		{name: "a space around it is still that one", theme: " second ", want: "second"},
		{name: "one it does not", theme: "gruvbox", fails: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got, err := (Options{Theme: tc.theme}).ThemeChoice(catalogue)
			if tc.fails {
				if err == nil {
					t.Fatalf("accepted %q, and the release offers %v", tc.theme, catalogue.IDs())
				}
				// The refusal has to say what is on offer, or somebody is left
				// guessing at a list they cannot see.
				for _, id := range catalogue.IDs() {
					if !strings.Contains(err.Error(), id) {
						t.Errorf("the refusal does not mention %q: %v", id, err)
					}
				}
				return
			}
			if err != nil {
				t.Fatalf("ThemeChoice: %v", err)
			}
			if got != tc.want {
				t.Errorf("theme = %q, want %q", got, tc.want)
			}
		})
	}
}

// A release that offers nothing has no answer to give, and asking for one is
// misuse rather than something to quietly ignore.
func TestAThemeAskedOfAReleaseThatOffersNoneIsRefused(t *testing.T) {
	got, err := (Options{}).ThemeChoice(theme.Catalogue{})
	if err != nil || got != "" {
		t.Errorf("ThemeChoice = %q, %v; want nothing to record and no error", got, err)
	}

	if _, err := (Options{Theme: "first"}).ThemeChoice(theme.Catalogue{}); err == nil {
		t.Error("accepted --theme against a release that offers no choice of theme")
	}
}
