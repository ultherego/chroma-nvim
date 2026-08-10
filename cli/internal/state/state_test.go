package state

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// fixtures are shared with the Lua reader. Both are driven by the same files so
// that "Go accepts, Lua rejects" is a failing test rather than a machine
// behaving differently from the editor on it.
const fixtures = "../../../tests/fixtures/component-state"

func shipped(t *testing.T) component.Set {
	t.Helper()

	set, problems, err := component.Load(filepath.Join("..", "..", "..", "components"))
	if err != nil || len(problems) > 0 {
		t.Fatalf("loading the shipped contract: %v %v", err, problems)
	}
	return set
}

func TestValidFixturesLoad(t *testing.T) {
	set := shipped(t)

	entries, err := os.ReadDir(filepath.Join(fixtures, "valid"))
	if err != nil {
		t.Fatalf("reading the fixtures: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("no valid fixtures, which would make this pass for nothing")
	}

	for _, entry := range entries {
		t.Run(entry.Name(), func(t *testing.T) {
			state, found, err := Load(filepath.Join(fixtures, "valid", entry.Name()), set)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if !found {
				t.Error("found = false for a file that is there")
			}
			if state.Schema != Schema {
				t.Errorf("schema = %d, want %d", state.Schema, Schema)
			}
		})
	}
}

func TestInvalidFixturesAreRefused(t *testing.T) {
	set := shipped(t)

	entries, err := os.ReadDir(filepath.Join(fixtures, "invalid"))
	if err != nil {
		t.Fatalf("reading the fixtures: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("no invalid fixtures, which would make this pass for nothing")
	}

	for _, entry := range entries {
		t.Run(entry.Name(), func(t *testing.T) {
			if _, _, err := Load(filepath.Join(fixtures, "invalid", entry.Name()), set); err == nil {
				t.Error("accepted a file the corpus says is invalid")
			}
		})
	}
}

// The distinction the whole migration rests on: no file at all is not an empty
// selection. An upgrade must not switch off the Terraform support somebody has
// been using for months.
func TestMissingFileIsNotAnEmptySelection(t *testing.T) {
	set := shipped(t)

	state, found, err := Load(filepath.Join(t.TempDir(), "components.json"), set)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if found {
		t.Fatal("found = true for a file that is not there")
	}
	if len(state.Selected) != 0 {
		t.Errorf("selected = %v, want empty", state.Selected)
	}

	// And the caller can tell the two apart by what it does next.
	legacy := EnabledLegacy(set)
	if len(legacy) != len(set) {
		t.Errorf("legacy enables %d of %d components", len(legacy), len(set))
	}

	empty, _, err := Load(filepath.Join(fixtures, "valid", "core-only.json"), set)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got := empty.Enabled(set); len(got) != 1 || got[0] != Core {
		t.Errorf("an empty selection enables %v, want core alone", got)
	}
}

// Resolved on read, never stored: a component whose dependencies change must
// not be described by a list written before the change.
func TestEnabledResolvesThroughTheGraph(t *testing.T) {
	set := component.Set{
		"core":  {ID: "core"},
		"mid":   {ID: "mid", Requires: []string{"core"}},
		"leaf":  {ID: "leaf", Requires: []string{"mid"}},
		"other": {ID: "other", Requires: []string{"core"}},
	}

	got := State{Schema: Schema, Selected: []string{"leaf"}}.Enabled(set)
	if strings.Join(got, ",") != "core,leaf,mid" {
		t.Errorf("enabled = %v, want core, leaf and mid", got)
	}
	for _, id := range got {
		if id == "other" {
			t.Error("something nobody selected was enabled")
		}
	}
}

func TestPathFollowsXDG(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "/somewhere")
	got, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}
	if got != filepath.Join("/somewhere", "chroma", "components.json") {
		t.Errorf("Path() = %q", got)
	}
}

// The file is read at startup by an editor that decides what to load from it, so
// a half-written selection is a Chroma that comes up wrong.
func TestWriteIsAtomicAndReadable(t *testing.T) {
	set := shipped(t)
	path := filepath.Join(t.TempDir(), "nested", "components.json")

	if _, err := Write(path, State{Selected: []string{"terraform", "aws"}}, set); err != nil {
		t.Fatalf("Write: %v", err)
	}

	state, found, err := Load(path, set)
	if err != nil || !found {
		t.Fatalf("reading back: %v found=%v", err, found)
	}
	// Sorted on the way out, so two runs that chose the same things produce the
	// same file and a diff means something.
	if strings.Join(state.Selected, ",") != "aws,terraform" {
		t.Errorf("selected = %v", state.Selected)
	}

	// Nothing left behind from the replacement.
	entries, err := os.ReadDir(filepath.Dir(path))
	if err != nil {
		t.Fatalf("reading the directory: %v", err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), ".components.") {
			t.Errorf("a temporary file survived: %s", entry.Name())
		}
	}
}

func TestWriteReplacesRatherThanAppends(t *testing.T) {
	set := shipped(t)
	path := filepath.Join(t.TempDir(), "components.json")

	if _, err := Write(path, State{Selected: []string{"terraform", "aws", "docker"}}, set); err != nil {
		t.Fatalf("Write: %v", err)
	}
	if _, err := Write(path, State{Selected: []string{"vault"}}, set); err != nil {
		t.Fatalf("Write: %v", err)
	}

	state, _, err := Load(path, set)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if strings.Join(state.Selected, ",") != "vault" {
		t.Errorf("selected = %v, want vault alone", state.Selected)
	}
}

// The writer is held to the reader's rules, because the alternative is a CLI
// that can talk an editor into safe mode: every one of these produces a file
// the next startup refuses, and the caller would have been told it succeeded.
func TestWriteRefusesWhatLoadWouldRefuse(t *testing.T) {
	set := shipped(t)

	for _, tc := range []struct {
		name     string
		selected []string
		contains string
	}{
		{"core, which is not a choice", []string{"core"}, "not a choice"},
		{"a duplicate", []string{"vault", "vault"}, "twice"},
		{"a component that does not exist", []string{"magic"}, "unknown component"},
		{"an empty id", []string{""}, "empty id"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "components.json")

			_, err := Write(path, State{Selected: tc.selected}, set)
			if err == nil {
				t.Fatal("Write accepted a selection Load would refuse")
			}
			if !strings.Contains(err.Error(), tc.contains) {
				t.Errorf("err = %v, want it to name the problem", err)
			}

			// And it refused before it wrote, rather than leaving the file behind.
			if _, err := os.Stat(path); !os.IsNotExist(err) {
				t.Errorf("a refused selection still produced a file")
			}
		})
	}
}

// The property the two halves owe each other: anything this writes, it reads.
func TestEveryValidFixtureSurvivesARoundTrip(t *testing.T) {
	set := shipped(t)

	entries, err := os.ReadDir(filepath.Join(fixtures, "valid"))
	if err != nil {
		t.Fatalf("reading the fixtures: %v", err)
	}
	if len(entries) == 0 {
		t.Fatal("no valid fixtures, which would make this pass for nothing")
	}

	for _, entry := range entries {
		t.Run(entry.Name(), func(t *testing.T) {
			original, _, err := Load(filepath.Join(fixtures, "valid", entry.Name()), set)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}

			path := filepath.Join(t.TempDir(), "components.json")
			if _, err := Write(path, original, set); err != nil {
				t.Fatalf("Write: %v", err)
			}

			again, found, err := Load(path, set)
			if err != nil || !found {
				t.Fatalf("reading back: %v found=%v", err, found)
			}
			if strings.Join(again.Selected, ",") != strings.Join(original.Selected, ",") {
				t.Errorf("round trip changed the selection: %v became %v", original.Selected, again.Selected)
			}
		})
	}
}

// Writing state relative to whatever directory the CLI was run from is not a
// fallback, it is a different file — one the editor never reads.
func TestPathRefusesToGuess(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("HOME", "")

	if got, err := Path(); err == nil {
		t.Errorf("Path() = %q with nowhere to put it, want an error", got)
	}
}

// Naming core is refused rather than ignored: silently dropping it would accept
// a file written against a different idea of what this document means.
func TestCoreIsNotAChoice(t *testing.T) {
	_, _, err := Load(filepath.Join(fixtures, "invalid", "core-selected.json"), shipped(t))
	if err == nil || !strings.Contains(err.Error(), "not a choice") {
		t.Errorf("err = %v, want a refusal naming core", err)
	}
}

// A typo and "a newer CLI wrote this for an older Chroma" look the same here,
// and both mean the configuration about to run is not the one that was chosen.
func TestUnknownComponentIsRefused(t *testing.T) {
	_, _, err := Load(filepath.Join(fixtures, "invalid", "unknown-component.json"), shipped(t))
	if err == nil || !strings.Contains(err.Error(), "unknown component") {
		t.Errorf("err = %v, want a refusal naming the component", err)
	}
}
