package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// installed puts a first generation on a fresh machine and returns what it
// recorded, so an update has something real to replace.
func installed(t *testing.T, selected []string) (Paths, installstate.State) {
	t.Helper()
	return installedUnder(t, t.TempDir(), selected)
}

// installedUnder is the same, in a directory the caller chose — which a crash
// test needs, because the child process has to leave its tree somewhere the
// parent can look at afterwards.
func installedUnder(t *testing.T, root string, selected []string) (Paths, installstate.State) {
	t.Helper()

	xdg(t, root)
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Apply(context.Background(), Options{Selected: selected}, paths, prepared(t), shipped(t))
	if err != nil {
		t.Fatalf("the first installation failed: %v", err)
	}

	// A tree installation records no version. Updates are release to release,
	// so the case under test is given one.
	record := result.State
	record.Version = "v1.0.0"
	record.Source = installstate.Source{Type: installstate.FromRelease, Ref: "v1.0.0", SHA256: "old"}
	if _, err := installstate.Write(paths.InstallState, record); err != nil {
		t.Fatalf("Write: %v", err)
	}

	return paths, record
}

// updated runs an update over that installation.
func updated(t *testing.T, runner Runner, paths Paths, current installstate.State, selected []string) (Result, error) {
	t.Helper()

	installer := &Installer{Runner: runner}
	return installer.Update(context.Background(), paths, prepared(t), shipped(t), selected, current)
}

// The point of the milestone: after an update there are two generations and the
// record says which is which. Rollback has nothing to go back to otherwise.
func TestAnUpdateRecordsThePreviousGeneration(t *testing.T) {
	fixed(t)

	paths, current := installed(t, []string{"terraform"})
	result, err := updated(t, &failAt{}, paths, current, []string{"terraform"})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}

	if record.Previous == nil {
		t.Fatal("the update recorded no previous generation")
	}
	if record.Previous.Version != "v1.0.0" {
		t.Errorf("previous version = %q, want v1.0.0", record.Previous.Version)
	}
	if record.Previous.Source.Ref != "v1.0.0" {
		t.Errorf("previous source = %+v, want the release it came from", record.Previous.Source)
	}

	// The path has to be somewhere that exists, or the record promises a way
	// back to nothing.
	if record.Previous.Path == "" {
		t.Fatal("the previous generation has no path")
	}
	if !exists(record.Previous.Path) {
		t.Errorf("previous generation is recorded at %s, which is not there", record.Previous.Path)
	}
	if !exists(filepath.Join(record.Previous.Path, "init.lua")) {
		t.Errorf("%s does not hold a configuration", record.Previous.Path)
	}

	if record.Previous.Path != result.State.Backup {
		t.Errorf("previous path %q and backup %q disagree", record.Previous.Path, result.State.Backup)
	}
}

// An update always moves the current generation aside. Installing over it would
// leave nothing to roll back to, whatever the record said.
func TestAnUpdateAlwaysBacksUp(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)

	// A file only the old generation has, to tell the two apart afterwards.
	marker := filepath.Join(paths.ConfigDir, "generation-one")
	if err := os.WriteFile(marker, []byte("first"), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := updated(t, &failAt{}, paths, current, nil)
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	if result.State.Backup == "" {
		t.Fatal("the update moved nothing aside")
	}
	if !exists(filepath.Join(result.State.Backup, "generation-one")) {
		t.Error("the old generation was not the thing moved aside")
	}
	if exists(filepath.Join(paths.ConfigDir, "generation-one")) {
		t.Error("the new generation still holds the old one's files")
	}
}

// A failure after the old generation has moved has to put it back. This is the
// case that decides whether a failed update leaves somebody without an editor.
func TestAFailedUpdateRestoresTheGenerationItReplaced(t *testing.T) {
	for _, step := range []string{"install", "verify"} {
		t.Run("failing at "+step, func(t *testing.T) {
			fixed(t)

			paths, current := installed(t, nil)
			marker := filepath.Join(paths.ConfigDir, "generation-one")
			if err := os.WriteFile(marker, []byte("first"), 0o644); err != nil {
				t.Fatal(err)
			}

			result, err := updated(t, &failAt{step: step}, paths, current, nil)
			if err == nil {
				t.Fatal("the update reported success although the editor refused")
			}
			if !result.RolledBack {
				t.Error("the update did not roll back")
			}
			if result.RollbackProblem != nil {
				t.Errorf("the rollback itself failed: %v", result.RollbackProblem)
			}

			if !exists(marker) {
				t.Error("the generation that was working is gone")
			}

			// And the record still describes the installation that is actually
			// there, rather than the one that failed to arrive.
			record, found, err := installstate.Load(paths.InstallState)
			if err != nil || !found {
				t.Fatalf("Load: %v found=%v", err, found)
			}
			if record.Version != "v1.0.0" {
				t.Errorf("the record says %q after a failed update, want v1.0.0", record.Version)
			}
			if record.Previous != nil {
				t.Errorf("a failed update recorded a previous generation: %+v", record.Previous)
			}
		})
	}
}

// The selection is carried in rather than asked for, and it is what decides
// what the new generation enables.
func TestAnUpdateKeepsTheSelectionItWasGiven(t *testing.T) {
	fixed(t)

	paths, current := installed(t, []string{"terraform"})
	result, err := updated(t, &failAt{}, paths, current, []string{"terraform"})
	if err != nil {
		t.Fatalf("Update: %v", err)
	}

	if len(result.Selected) != 1 || result.Selected[0] != "terraform" {
		t.Errorf("selected = %v, want the selection it was given", result.Selected)
	}

	contents, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatalf("reading the selection: %v", err)
	}
	if !strings.Contains(string(contents), "terraform") {
		t.Errorf("the selection document lost the component: %s", contents)
	}
}
