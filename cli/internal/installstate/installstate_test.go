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
		CacheDir:      "/home/somebody/.cache/chroma-nvim",
		SelectionFile: "/home/somebody/.config/chroma/components.json",
		InstalledAt:   "2026-08-09T13:42:00Z",
		Source:        Source{Type: FromRelease, Ref: "v1.0.0", SHA256: "abc123"},
	}
}

func TestARecordSurvivesARoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	if _, err := Write(path, whole()); err != nil {
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
			_, err := Write(path, state)
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
		{
			// The number is pinned deliberately. Write and validate share the
			// constant, so nothing else notices if it moves — and what it
			// controls is whether a record an older Chroma wrote is read or
			// refused. Schema 1 could not say what a backup held, so a rollback
			// against one would restore a directory it cannot name.
			name: "a schema from before the user backup was recorded",
			contents: `{"schema": 2, "version": "v1", "contract": 5, "appname": "chroma-nvim",` +
				`"config_dir": "/a", "data_dir": "/b", "state_dir": "/c", "cache_dir": "/e", "selection_file": "/d",` +
				`"installed_at": "now", "source": {"type": "release"}}`,
			mention: "declares schema 2",
		},
		{"a field it does not know", `{"schema": 1, "colour": "peach"}`, "unknown field"},
		{"not JSON at all", `{ not json`, "install.json"},
		{
			name: "two documents",
			contents: `{"schema": 2, "version": "v1", "contract": 5, "appname": "chroma-nvim",` +
				`"config_dir": "/a", "data_dir": "/b", "state_dir": "/c", "cache_dir": "/e", "selection_file": "/d",` +
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
	if _, err := Write(path, state); err != nil {
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

// Schema 2 exists for this field, and rollback is the only reader of it.
func TestAPreviousGenerationSurvivesARoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.Version = "v2.0.0"
	record.Backup = "/home/somebody/.config/chroma-nvim.chroma-backup-20260809T134200Z"
	record.Previous = &Generation{
		Version:     "v1.0.0",
		Contract:    5,
		Path:        record.Backup,
		InstalledAt: "2026-08-09T13:42:00Z",
		Source:      Source{Type: FromRelease, Ref: "v1.0.0", SHA256: "abc123"},
	}

	if _, err := Write(path, record); err != nil {
		t.Fatalf("Write: %v", err)
	}

	read, found, err := Load(path)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	if read.Previous == nil {
		t.Fatal("the previous generation did not survive")
	}
	if read.Previous.Version != "v1.0.0" || read.Previous.Path != record.Backup {
		t.Errorf("read back %+v", read.Previous)
	}
	if read.Previous.Source.Ref != "v1.0.0" {
		t.Errorf("the previous source did not survive: %+v", read.Previous.Source)
	}
}

// A generation with nowhere to go back to is worse than no generation at all:
// it promises rollback a directory that is not there.
func TestAPreviousGenerationWithoutAPathIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.Previous = &Generation{Version: "v1.0.0", Source: Source{Type: FromRelease}}

	if _, err := Write(path, record); err == nil {
		t.Error("a previous generation with no path was recorded")
	}
	if _, found, _ := Load(path); found {
		t.Error("the refused record was written anyway")
	}
}

func TestAPreviousGenerationWithAnUnknownSourceIsRefused(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.Previous = &Generation{Path: "/somewhere", Source: Source{Type: "carrier pigeon"}}

	if _, err := Write(path, record); err == nil {
		t.Error("a previous generation with an unknown source type was recorded")
	}
}

// A first installation has no previous generation, and saying it has one would
// give rollback something to restore that was never replaced.
func TestAFirstInstallationRecordsNoPreviousGeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	if _, err := Write(path, whole()); err != nil {
		t.Fatalf("Write: %v", err)
	}

	read, _, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if read.Previous != nil {
		t.Errorf("previous = %+v, want none", read.Previous)
	}
}

// The user's own configuration and a Chroma generation are different things,
// and one path cannot be both. If it were, uninstall would remove the
// generation and take somebody's configuration with it.
func TestOnePathCannotBeBothAUserBackupAndAGeneration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.UserBackup = "/home/somebody/.config/nvim.chroma-backup-20260810T000000Z"
	record.Handover = HandoverHeld
	record.Previous = &Generation{
		Version: "v1.0.0",
		Path:    record.UserBackup,
		Source:  Source{Type: FromRelease},
	}

	if _, err := Write(path, record); err == nil {
		t.Error("a record naming one directory as both was accepted")
	}
}

// And the ordinary case still works: both set, to different places.
func TestAUserBackupAndAGenerationCoexist(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.UserBackup = "/home/somebody/.config/nvim.chroma-original"
	record.Handover = HandoverHeld
	record.Previous = &Generation{
		Version: "v1.0.0",
		Path:    "/home/somebody/.config/nvim.chroma-backup-20260810T000000Z",
		Source:  Source{Type: FromRelease},
	}

	if _, err := Write(path, record); err != nil {
		t.Fatalf("Write: %v", err)
	}

	read, _, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if read.UserBackup != record.UserBackup {
		t.Errorf("user_backup = %q, want %q", read.UserBackup, record.UserBackup)
	}
	if read.Previous == nil || read.Previous.Path == read.UserBackup {
		t.Errorf("the two came back as one: %+v", read.Previous)
	}
}

// A configuration cannot be both given back and still waiting to be given
// back. The two together would make the next uninstall move a directory it has
// already handed over.
func TestAHandedBackStateCannotAlsoNameSomethingToRestore(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.UserBackup = "/home/somebody/.config/nvim.chroma-original"
	record.Handover = HandoverHandedBack

	if _, err := Write(path, record); err == nil {
		t.Error("a record claiming both was accepted")
	}
}

func TestTheHandoverStateSurvivesARoundTrip(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")

	record := whole()
	record.Handover = HandoverHandedBack
	if _, err := Write(path, record); err != nil {
		t.Fatalf("Write: %v", err)
	}

	read, _, err := Load(path)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if read.Handover != HandoverHandedBack {
		t.Errorf("handover = %q, so a retry would move the user's configuration", read.Handover)
	}
}

// Every handover state has to agree with whether there is a path to hold.
func TestTheHandoverStateAndTheBackupPathMustAgree(t *testing.T) {
	for _, tc := range []struct {
		name     string
		handover Handover
		backup   string
	}{
		{"held with nothing to hold", HandoverHeld, ""},
		{"pending with nothing to transfer", HandoverPending, ""},
		{"none but a path to restore", HandoverNone, "/somewhere"},
		{"handed back but a path to restore", HandoverHandedBack, "/somewhere"},
		{"a state nobody defined", Handover("half"), "/somewhere"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "install.json")

			record := whole()
			record.Handover = tc.handover
			record.UserBackup = tc.backup

			if _, err := Write(path, record); err == nil {
				t.Errorf("handover %q with backup %q was accepted", tc.handover, tc.backup)
			}
		})
	}
}

func TestRemoveIsIdempotent(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")
	if _, err := Write(path, whole()); err != nil {
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

// One directory cannot be two things. Each of these aliases would send a
// destructive step at the wrong object.
func TestAliasedPathsAreRefused(t *testing.T) {
	for _, tc := range []struct {
		name  string
		build func(*State)
	}{
		{"the backup is the installation", func(s *State) {
			s.UserBackup = s.ConfigDir
			s.Handover = HandoverHeld
		}},
		{"the generation is the installation", func(s *State) {
			s.Previous = &Generation{Path: s.ConfigDir, Source: Source{Type: FromRelease}}
		}},
		{"the backup is the generation", func(s *State) {
			s.UserBackup = "/home/somebody/.config/nvim.kept"
			s.Handover = HandoverHeld
			s.Previous = &Generation{Path: s.UserBackup, Source: Source{Type: FromRelease}}
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "install.json")

			record := whole()
			tc.build(&record)

			if _, err := Write(path, record); err == nil {
				t.Error("a record naming one directory as two things was accepted")
			}
		})
	}
}
