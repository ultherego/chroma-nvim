package install

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// twoGenerations leaves a machine with v2 installed and v1 kept beside it, each
// carrying a marker so the two can be told apart on disk.
func twoGenerations(t *testing.T, selected []string) (Paths, installstate.State) {
	t.Helper()
	return twoGenerationsUnder(t, t.TempDir(), selected)
}

func twoGenerationsUnder(t *testing.T, root string, selected []string) (Paths, installstate.State) {
	t.Helper()

	paths, first := installedUnder(t, root, selected)
	if err := os.WriteFile(filepath.Join(paths.ConfigDir, "generation"), []byte("v1"), 0o644); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Update(context.Background(), paths, prepared(t), shipped(t), selected, first)
	if err != nil {
		t.Fatalf("the update failed: %v", err)
	}

	// The update installed a tree, which records no version. Give the second
	// generation one, the same way installed() does for the first.
	record := result.State
	record.Version = "v2.0.0"
	record.Source = installstate.Source{Type: installstate.FromRelease, Ref: "v2.0.0", SHA256: "new"}
	if _, err := installstate.Write(paths.InstallState, record); err != nil {
		t.Fatalf("Write: %v", err)
	}

	if err := os.WriteFile(filepath.Join(paths.ConfigDir, "generation"), []byte("v2"), 0o644); err != nil {
		t.Fatal(err)
	}

	return paths, record
}

func generationOnDisk(t *testing.T, paths Paths) string {
	t.Helper()

	contents, err := os.ReadFile(filepath.Join(paths.ConfigDir, "generation"))
	if err != nil {
		t.Fatalf("reading the generation marker: %v", err)
	}
	return string(contents)
}

// The whole command: the kept generation comes back, and what was current
// becomes the one to come back to.
func TestRollbackSwapsTheGenerations(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, []string{"terraform"})

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Rollback(context.Background(), paths, shipped(t), []string{"terraform"}, current)
	if err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if got := generationOnDisk(t, paths); got != "v1" {
		t.Errorf("the directory holds generation %q, want v1", got)
	}

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	if record.Version != "v1.0.0" {
		t.Errorf("version = %q, want v1.0.0", record.Version)
	}
	if record.Source.Ref != "v1.0.0" {
		t.Errorf("source = %+v, want the generation that was restored", record.Source)
	}
	if record.Previous == nil {
		t.Fatal("nothing was recorded to come back to")
	}
	if record.Previous.Version != "v2.0.0" {
		t.Errorf("previous = %q, want v2.0.0: a rollback swaps rather than pops", record.Previous.Version)
	}
	if !exists(filepath.Join(record.Previous.Path, "init.lua")) {
		t.Errorf("the generation that was left is not kept at %s", record.Previous.Path)
	}
	if result.State.Version != record.Version {
		t.Errorf("the result and the record disagree: %q and %q", result.State.Version, record.Version)
	}
}

// And rolling back again returns. One slot, two directions.
func TestRollingBackAgainReturns(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	installer := &Installer{Runner: &failAt{}}

	first, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current)
	if err != nil {
		t.Fatalf("the first rollback failed: %v", err)
	}
	if got := generationOnDisk(t, paths); got != "v1" {
		t.Fatalf("after one rollback the directory holds %q, want v1", got)
	}

	second, err := installer.Rollback(context.Background(), paths, shipped(t), nil, first.State)
	if err != nil {
		t.Fatalf("the second rollback failed: %v", err)
	}

	if got := generationOnDisk(t, paths); got != "v2" {
		t.Errorf("after two rollbacks the directory holds %q, want v2", got)
	}
	if second.State.Version != "v2.0.0" {
		t.Errorf("version = %q, want v2.0.0", second.State.Version)
	}
	if second.State.Previous == nil || second.State.Previous.Version != "v1.0.0" {
		t.Errorf("previous = %+v, want v1.0.0", second.State.Previous)
	}
}

// The case that decides whether a rollback is safe to try: a failure after both
// directories have moved must put both of them back.
func TestAFailedRollbackLeavesTheGenerationYouWereOn(t *testing.T) {
	for _, step := range []string{"install", "verify"} {
		t.Run("failing at "+step, func(t *testing.T) {
			fixed(t)

			paths, current := twoGenerations(t, []string{"terraform"})
			keptAt := current.Previous.Path

			selection, err := os.ReadFile(paths.SelectionFile)
			if err != nil {
				t.Fatal(err)
			}

			installer := &Installer{Runner: &failAt{step: step}}
			result, err := installer.Rollback(context.Background(), paths, shipped(t), []string{"terraform"}, current)
			if err == nil {
				t.Fatal("the rollback reported success although the editor refused")
			}
			if !result.RolledBack {
				t.Error("the rollback did not undo itself")
			}
			if result.RollbackProblem != nil {
				t.Errorf("undoing the rollback failed: %v", result.RollbackProblem)
			}

			if got := generationOnDisk(t, paths); got != "v2" {
				t.Errorf("the directory holds generation %q, want v2 back where it was", got)
			}

			// The kept generation is still kept, and still where the record says
			// it is. Deleting it would have destroyed the only way back.
			if !exists(filepath.Join(keptAt, "init.lua")) {
				t.Errorf("the previous generation is gone from %s", keptAt)
			}

			record, found, err := installstate.Load(paths.InstallState)
			if err != nil || !found {
				t.Fatalf("Load: %v found=%v", err, found)
			}
			if record.Version != "v2.0.0" {
				t.Errorf("version = %q after a failed rollback, want v2.0.0", record.Version)
			}
			if record.Previous == nil || record.Previous.Path != keptAt {
				t.Errorf("previous = %+v, want it still pointing at %s", record.Previous, keptAt)
			}

			after, err := os.ReadFile(paths.SelectionFile)
			if err != nil {
				t.Fatal(err)
			}
			if string(after) != string(selection) {
				t.Errorf("the selection changed:\nbefore %s\nafter  %s", selection, after)
			}
		})
	}
}

// A rollback moves the version. It does not undo a choice made since.
func TestRollbackKeepsTheCurrentSelection(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, []string{"terraform"})

	// A component chosen after the update, which the rollback must not revert.
	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Reconfigure(context.Background(), paths, shipped(t), []string{"terraform", "kubernetes"}); err != nil {
		t.Fatalf("Reconfigure: %v", err)
	}

	result, err := installer.Rollback(context.Background(), paths, shipped(t), []string{"terraform", "kubernetes"}, current)
	if err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	contents, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"terraform", "kubernetes"} {
		if !strings.Contains(string(contents), `"`+id+`"`) {
			t.Errorf("the selection lost %q: %s", id, contents)
		}
	}
	if len(result.Selected) != 2 {
		t.Errorf("selected = %v, want both components", result.Selected)
	}
}

// Nothing to go back to is an error rather than a no-op: a caller that asked
// for a rollback got none, and should be told.
func TestRollbackWithNoPreviousGenerationIsRefused(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current); err == nil {
		t.Error("a rollback with no previous generation reported success")
	}
}

// touching is a runner whose bootstrap changes the top level of the tree it
// runs in, the way a real one can, and then fails at the step named.
type touching struct {
	paths Paths
	fail  string
}

func (r *touching) Run(_ context.Context, cmd Command, _ ProgressSink) error {
	if err := os.WriteFile(filepath.Join(r.paths.ConfigDir, "lazy-lock.json.new"), []byte("{}"), 0o644); err != nil {
		return err
	}
	// Far enough apart for any filesystem's timestamps to tell.
	later := time.Now().Add(time.Hour)
	if err := os.Chtimes(r.paths.ConfigDir, later, later); err != nil {
		return err
	}
	if strings.Contains(strings.Join(cmd.Args, " "), `run("`+r.fail+`"`) {
		return errors.New("the editor said no")
	}
	return nil
}

// Regression: a rollback that failed put the kept generation back with a new
// mtime, and it was then "not the generation Chroma recorded" — every later
// rollback refused, for good.
func TestAFailedRollbackDoesNotCostTheNextOne(t *testing.T) {
	stepping(t)

	paths, record := twoGenerations(t, nil)

	failing := &Installer{Runner: &touching{paths: paths, fail: "verify"}}
	if _, err := failing.Rollback(context.Background(), paths, shipped(t), nil, record); err == nil {
		t.Fatal("the rollback succeeded, and it was meant to fail")
	}

	after := reload(t, paths)
	if after.Previous == nil || after.Previous.Path != record.Previous.Path {
		t.Fatalf("the kept generation is recorded as %+v", after.Previous)
	}

	working := &Installer{Runner: &failAt{}}
	if _, err := working.Rollback(context.Background(), paths, shipped(t), nil, after); err != nil {
		t.Fatalf("the next rollback was refused: %v", err)
	}
}

// Counted once. The configuration of an installation of its own is both on the
// plan and moved aside, and was reported removed twice.
func TestAnUninstallCountsEachPathOnce(t *testing.T) {
	fixed(t)

	paths, record := installed(t, nil)
	removal, err := (&Installer{}).Uninstall(paths, record)
	if err != nil {
		t.Fatal(err)
	}

	seen := map[string]int{}
	for _, path := range removal.Removed {
		seen[path]++
	}
	for path, times := range seen {
		if times != 1 {
			t.Errorf("%s is reported removed %d times", path, times)
		}
	}
	if seen[paths.ConfigDir] != 1 {
		t.Errorf("the configuration is reported removed %d times, want once", seen[paths.ConfigDir])
	}
}
