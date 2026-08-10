package install

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// stopAt makes one boundary the end of the operation, and only that one.
//
// The steps before it run for real and succeed for real. That is the whole
// point: a simulated failure inside a step tests the step's error handling,
// which the runner-based tests already do; stopping between two successes tests
// the boundary, which nothing else can reach.
func stopAt(t *testing.T, point faultPoint) error {
	t.Helper()

	stopped := errors.New("the process stopped here")
	faults = func(at faultPoint) error {
		if at == point {
			return stopped
		}
		return nil
	}
	t.Cleanup(func() { faults = nil })

	return stopped
}

// world is the control-plane state, which is the only thing these tests assert
// on. Whether a plugin directory has 300 megabytes in it says nothing about
// whether the transaction is consistent.
type world struct {
	Record     installstate.State
	Recorded   bool
	Selection  string
	Config     string
	ConfigHas  bool
	Beside     []string
	UserBackup bool
}

func observe(t *testing.T, paths Paths, userBackup string) world {
	t.Helper()

	got := world{}
	record, found, err := installstate.Load(paths.InstallState)
	if err != nil && found {
		t.Fatalf("the record cannot be read: %v", err)
	}
	got.Record, got.Recorded = record, found

	if contents, err := os.ReadFile(paths.SelectionFile); err == nil {
		got.Selection = string(contents)
	}
	if contents, err := os.ReadFile(filepath.Join(paths.ConfigDir, "generation")); err == nil {
		got.Config = string(contents)
	}
	got.ConfigHas = exists(filepath.Join(paths.ConfigDir, "init.lua"))
	if userBackup != "" {
		got.UserBackup = exists(filepath.Join(userBackup, "init.lua"))
	}

	entries, err := os.ReadDir(filepath.Dir(paths.ConfigDir))
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Base(paths.ConfigDir)
	for _, entry := range entries {
		if entry.Name() != base && strings.HasPrefix(entry.Name(), base) {
			got.Beside = append(got.Beside, entry.Name())
		}
	}
	return got
}

// The most important boundary in the whole lifecycle: the user's configuration
// has been taken out of the way and not yet given back. Nothing else in Chroma
// holds somebody else's data in the air.
func TestUninstallStoppedBeforeTheRestoreGivesChromaBack(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)
	before := observe(t, paths, userBackup)

	stopped := stopAt(t, faultAfterCurrentMoved)

	installer := &Installer{}
	_, err := installer.Uninstall(paths, current)
	if !errors.Is(err, stopped) {
		t.Fatalf("err = %v, want the stop to surface", err)
	}

	after := observe(t, paths, userBackup)

	if !after.ConfigHas {
		t.Error("the configuration directory is empty: Chroma was not put back")
	}
	if !after.UserBackup {
		t.Error("the configuration the user had before Chroma is gone")
	}
	if !after.Recorded || after.Record.Version != before.Record.Version {
		t.Errorf("the record changed: %+v", after.Record)
	}
	if after.Selection != before.Selection {
		t.Errorf("the selection changed:\nbefore %s\nafter  %s", before.Selection, after.Selection)
	}
	if len(after.Beside) != len(before.Beside) {
		t.Errorf("directories beside the configuration changed: %v → %v", before.Beside, after.Beside)
	}
}

// And the other side of the commit point. Once the user's configuration is back
// where it belongs, Chroma does not move it again — not even to reinstate an
// installation somebody has just asked to remove.
func TestUninstallStoppedAfterTheRestoreLeavesTheUserAlone(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)
	mine, err := os.ReadFile(filepath.Join(userBackup, "init.lua"))
	if err != nil {
		t.Fatal(err)
	}

	stopped := stopAt(t, faultAfterUserRestore)

	installer := &Installer{}
	removal, err := installer.Uninstall(paths, current)
	if !errors.Is(err, stopped) {
		t.Fatalf("err = %v, want the stop to surface", err)
	}
	if removal.Restored != userBackup {
		t.Errorf("restored = %q, want the restore to have happened before the stop", removal.Restored)
	}

	// The user's configuration is in place and is theirs.
	back, err := os.ReadFile(filepath.Join(paths.ConfigDir, "init.lua"))
	if err != nil {
		t.Fatalf("the user's configuration is not at %s: %v", paths.ConfigDir, err)
	}
	if string(back) != string(mine) {
		t.Errorf("%s holds %q, want the user's own %q", paths.ConfigDir, back, mine)
	}

	// And what is left is retryable: the record is still there, so a second run
	// knows what it was managing and can finish the deletions.
	if !exists(paths.InstallState) {
		t.Fatal("the record is gone, so nothing knows what is left to clean up")
	}

	// A second run is a second process: it reads the record again rather than
	// carrying the one this test started with, which is what `managed` does for
	// every command.
	faults = nil
	reloaded, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("reloading the record: %v found=%v", err, found)
	}
	if reloaded.UserBackup != "" {
		t.Errorf("the record still offers to restore %q after it has been given back", reloaded.UserBackup)
	}

	if _, err := installer.Uninstall(paths, reloaded); err != nil {
		t.Fatalf("the second attempt did not finish: %v", err)
	}

	again, err := os.ReadFile(filepath.Join(paths.ConfigDir, "init.lua"))
	if err != nil {
		t.Fatalf("the second attempt took the user's configuration: %v", err)
	}
	if string(again) != string(mine) {
		t.Errorf("the second attempt replaced the user's configuration with %q", again)
	}
	if exists(paths.InstallState) || exists(paths.DataDir) {
		t.Error("the second attempt left Chroma's own paths behind")
	}
}

// An update stopped between placing the new tree and writing the record has to
// put the old one back: the record still describes it, and a tree the record
// does not describe is an installation nothing can act on.
func TestUpdateStoppedBeforeTheRecordPutsTheOldGenerationBack(t *testing.T) {
	for _, point := range []faultPoint{faultAfterPlace, faultAfterVerify} {
		t.Run(string(point), func(t *testing.T) {
			fixed(t)

			paths, current := installed(t, []string{"terraform"})
			if err := os.WriteFile(filepath.Join(paths.ConfigDir, "generation"), []byte("v1"), 0o644); err != nil {
				t.Fatal(err)
			}
			before := observe(t, paths, "")

			stopped := stopAt(t, point)

			installer := &Installer{Runner: &failAt{}}
			result, err := installer.Update(context.Background(), paths, prepared(t), shipped(t), []string{"terraform"}, current)
			if !errors.Is(err, stopped) {
				t.Fatalf("err = %v, want the stop to surface", err)
			}
			if !result.RolledBack {
				t.Error("the update did not roll back")
			}

			after := observe(t, paths, "")
			if after.Config != "v1" {
				t.Errorf("the configuration is generation %q, want v1 back", after.Config)
			}
			if after.Record.Version != before.Record.Version {
				t.Errorf("the record says %q, want %q", after.Record.Version, before.Record.Version)
			}
			if after.Record.Previous != nil {
				t.Errorf("a stopped update recorded a generation to go back to: %+v", after.Record.Previous)
			}
			if len(after.Beside) != len(before.Beside) {
				t.Errorf("directories beside the configuration changed: %v → %v", before.Beside, after.Beside)
			}
		})
	}
}

// A rollback stopped after both directories have moved has to move both back.
// This is the boundary `Restored` was separated from `Placed` for.
func TestRollbackStoppedAfterTheRestoreMovesBothBack(t *testing.T) {
	for _, point := range []faultPoint{faultAfterRestore, faultAfterVerify} {
		t.Run(string(point), func(t *testing.T) {
			fixed(t)

			paths, current := twoGenerations(t, nil)
			keptAt := current.Previous.Path
			before := observe(t, paths, "")

			stopped := stopAt(t, point)

			installer := &Installer{Runner: &failAt{}}
			if _, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current); !errors.Is(err, stopped) {
				t.Fatalf("err = %v, want the stop to surface", err)
			}

			after := observe(t, paths, "")
			if after.Config != "v2" {
				t.Errorf("the configuration is generation %q, want v2 where it was", after.Config)
			}
			if !exists(filepath.Join(keptAt, "init.lua")) {
				t.Errorf("the kept generation is gone from %s", keptAt)
			}
			if after.Record.Version != before.Record.Version {
				t.Errorf("the record says %q, want %q", after.Record.Version, before.Record.Version)
			}
		})
	}
}

// A component change stopped after the editor is happy but before the change is
// kept has to leave the selection that was in force.
func TestComponentsStoppedAfterTheEditorLeavesTheOldSelection(t *testing.T) {
	for _, point := range []faultPoint{faultAfterBootstrap, faultAfterVerify} {
		t.Run(string(point), func(t *testing.T) {
			fixed(t)

			paths, _ := installed(t, []string{"terraform"})
			before := observe(t, paths, "")

			stopped := stopAt(t, point)

			installer := &Installer{Runner: &failAt{}}
			if _, err := installer.Reconfigure(context.Background(), paths, shipped(t), []string{"kubernetes"}); !errors.Is(err, stopped) {
				t.Fatalf("err = %v, want the stop to surface", err)
			}

			after := observe(t, paths, "")
			if after.Selection != before.Selection {
				t.Errorf("the selection changed:\nbefore %s\nafter  %s", before.Selection, after.Selection)
			}
			if strings.Contains(after.Selection, "kubernetes") {
				t.Error("the selection that never took effect is the one in force")
			}
			if after.Record.InstalledAt != before.Record.InstalledAt {
				t.Error("a component change touched the record")
			}
		})
	}
}

// Production carries no way to do any of this.
func TestNoFaultsAreArmedByDefault(t *testing.T) {
	if faults != nil {
		t.Fatal("a fault injector is armed outside a test that set one")
	}
	if err := hit(faultAfterVerify); err != nil {
		t.Errorf("hit returned %v with nothing armed", err)
	}
}
