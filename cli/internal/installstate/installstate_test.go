package installstate

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func whole() State {
	return State{
		Version:       "v1.0.0",
		Contract:      4,
		AppName:       "chroma-nvim",
		ConfigDir:     "/home/somebody/.config/chroma-nvim",
		DataDir:       "/home/somebody/.local/share/chroma-nvim",
		StateDir:      "/home/somebody/.local/state/chroma-nvim",
		SelectionFile: "/home/somebody/.config/chroma/components.json",
		InstalledAt:   "2026-08-09T13:42:00Z",
		Source:        Source{Type: FromRelease, Ref: "v1.0.0", SHA256: "abc123"},
	}
}

func TestARecordSurvivesARoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	if err := Write(path, whole()); err != nil {
		t.Fatalf("Write: %v", err)
	}

	state, found, err := Load(path)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	if state.Schema != Schema {
		t.Errorf("schema = %d, want %d", state.Schema, Schema)
	}
	if state.ConfigDir != whole().ConfigDir || state.Source.SHA256 != "abc123" {
		t.Errorf("read back %+v", state)
	}
}

// Not a managed installation is an ordinary thing for `install` to find and the
// exact thing `update` has to refuse, so the two are told apart rather than
// both arriving as an error.
func TestNoRecordIsNotAnError(t *testing.T) {
	state, found, err := Load(filepath.Join(t.TempDir(), "install.json"))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if found {
		t.Error("found = true for a file that is not there")
	}
	if state.ConfigDir != "" {
		t.Errorf("state = %+v, want the zero value", state)
	}
}

// Every one of these is a path something later acts on: update places over the
// config directory, uninstall deletes what is named. A record that does not say
// where it is cannot be acted on safely, so it is refused on the way in and on
// the way out.
func TestARecordThatCannotBeActedOnIsRefused(t *testing.T) {
	for _, tc := range []struct {
		name    string
		break_  func(s *State)
		mention string
	}{
		{"no config directory", func(s *State) { s.ConfigDir = "" }, "config_dir"},
		{"no data directory", func(s *State) { s.DataDir = "" }, "data_dir"},
		{"no state directory", func(s *State) { s.StateDir = "" }, "state_dir"},
		{"no selection file", func(s *State) { s.SelectionFile = "" }, "selection_file"},
		{"no timestamp", func(s *State) { s.InstalledAt = "" }, "installed_at"},
		{"a source from nowhere", func(s *State) { s.Source.Type = "magic" }, "unknown source type"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			state := whole()
			tc.break_(&state)

			path := filepath.Join(t.TempDir(), "install.json")
			err := Write(path, state)
			if err == nil {
				t.Fatal("recorded an installation that cannot be acted on")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to name the field", err)
			}
			if _, statErr := os.Stat(path); !os.IsNotExist(statErr) {
				t.Error("a refused record still produced a file")
			}
		})
	}
}

func TestAReaderRefusesWhatItDoesNotUnderstand(t *testing.T) {
	for _, tc := range []struct {
		name     string
		contents string
		mention  string
	}{
		{"a schema from the future", `{"schema": 99, "config_dir": "/x"}`, "declares schema 99"},
		{"a field it does not know", `{"schema": 1, "colour": "peach"}`, "unknown field"},
		{"not JSON at all", `{ not json`, "install.json"},
		{
			name: "two documents",
			contents: `{"schema": 1, "version": "v1", "contract": 5, "appname": "chroma-nvim",` +
				`"config_dir": "/a", "data_dir": "/b", "state_dir": "/c", "selection_file": "/d",` +
				`"installed_at": "now", "source": {"type": "tree"}}` + "\n" + `{"schema": 1}`,
			mention: "more than one document",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "install.json")
			if err := os.WriteFile(path, []byte(tc.contents), 0o644); err != nil {
				t.Fatalf("writing the fixture: %v", err)
			}

			_, found, err := Load(path)
			if err == nil {
				t.Fatal("accepted a record it should not understand")
			}
			if !found {
				t.Error("found = false for a file that is there")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to mention %q", err, tc.mention)
			}
		})
	}
}

// A tree installation has no version, and that is the fact update needs.
func TestATreeInstallationIsRecordedAsOne(t *testing.T) {
	state := whole()
	state.Version = ""
	state.Source = Source{Type: FromTree, Ref: "/home/somebody/Projects/chroma-nvim"}

	path := filepath.Join(t.TempDir(), "install.json")
	if err := Write(path, state); err != nil {
		t.Fatalf("Write: %v", err)
	}

	read, _, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if read.Version != "" || read.Source.Type != FromTree {
		t.Errorf("read %+v, want an unversioned tree installation", read)
	}
}

func TestRemoveIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")
	if err := Write(path, whole()); err != nil {
		t.Fatalf("Write: %v", err)
	}
	for i := 0; i < 2; i++ {
		if err := Remove(path); err != nil {
			t.Fatalf("Remove %d: %v", i, err)
		}
	}
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Error("the record is still there")
	}
}
