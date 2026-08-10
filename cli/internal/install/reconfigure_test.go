package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

func reconfigured(t *testing.T, runner Runner, paths Paths, selected []string) (Result, error) {
	t.Helper()

	installer := &Installer{Runner: runner}
	return installer.Reconfigure(context.Background(), paths, shipped(t), selected)
}

// The boundary this milestone rests on: which components somebody wants is not
// a release of Chroma, so changing it leaves the generation exactly as it was.
func TestChangingComponentsIsNotAGeneration(t *testing.T) {
	fixed(t)

	paths, before := installed(t, []string{"terraform"})

	if _, err := reconfigured(t, &failAt{}, paths, []string{"terraform", "kubernetes"}); err != nil {
		t.Fatalf("Reconfigure: %v", err)
	}

	after, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}

	if after.Version != before.Version {
		t.Errorf("version = %q, want it unchanged at %q", after.Version, before.Version)
	}
	if after.Source != before.Source {
		t.Errorf("source = %+v, want it unchanged", after.Source)
	}
	if after.Previous != nil {
		t.Errorf("a component change recorded a previous generation: %+v", after.Previous)
	}
	if after.InstalledAt != before.InstalledAt {
		t.Errorf("installed_at moved to %q; nothing was installed", after.InstalledAt)
	}
}

// And it moves no directory. A backup here would be a second copy of a tree
// that did not change, and a rollback target that means nothing.
func TestChangingComponentsMovesNoConfiguration(t *testing.T) {
	fixed(t)

	paths, _ := installed(t, nil)

	marker := filepath.Join(paths.ConfigDir, "placed-once")
	if err := os.WriteFile(marker, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}

	if _, err := reconfigured(t, &failAt{}, paths, []string{"terraform"}); err != nil {
		t.Fatalf("Reconfigure: %v", err)
	}

	if !exists(marker) {
		t.Error("the configuration was replaced; nothing about it should have changed")
	}

	entries, err := os.ReadDir(filepath.Dir(paths.ConfigDir))
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), "chroma-backup") {
			t.Errorf("a component change left a backup at %s", entry.Name())
		}
	}
}

// The selection is written before the editor is asked to come to it, and kept
// only if it does. This decides whether a mistyped component costs an editor.
func TestAFailedChangeLeavesTheOldSelectionInForce(t *testing.T) {
	for _, step := range []string{"install", "verify"} {
		t.Run("failing at "+step, func(t *testing.T) {
			fixed(t)

			paths, _ := installed(t, []string{"terraform"})

			before, err := os.ReadFile(paths.SelectionFile)
			if err != nil {
				t.Fatal(err)
			}

			result, err := reconfigured(t, &failAt{step: step}, paths, []string{"kubernetes"})
			if err == nil {
				t.Fatal("the change reported success although the editor refused")
			}
			if !result.RolledBack {
				t.Error("the change did not roll back")
			}
			if result.RollbackProblem != nil {
				t.Errorf("the rollback itself failed: %v", result.RollbackProblem)
			}

			after, err := os.ReadFile(paths.SelectionFile)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(before) {
				t.Errorf("the selection changed anyway:\nbefore %s\nafter  %s", before, after)
			}
			if strings.Contains(string(after), "kubernetes") {
				t.Error("the failed selection is the one in force")
			}
		})
	}
}

// A change that succeeds is the one in force, and the effective set is what the
// resolver says rather than what was typed.
func TestASuccessfulChangeIsWrittenAndResolved(t *testing.T) {
	fixed(t)

	paths, _ := installed(t, nil)

	result, err := reconfigured(t, &failAt{}, paths, []string{"terraform"})
	if err != nil {
		t.Fatalf("Reconfigure: %v", err)
	}

	contents, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(contents), "terraform") {
		t.Errorf("the selection does not hold the change: %s", contents)
	}

	// core is not in the document and is always in the effective set.
	if !strings.Contains(strings.Join(result.Enabled, ","), "core") {
		t.Errorf("enabled = %v, want core in it", result.Enabled)
	}
	if strings.Contains(string(contents), `"core"`) {
		t.Errorf("core was written into the selection document: %s", contents)
	}
}
