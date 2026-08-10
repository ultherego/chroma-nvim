package install

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// takenOver is an installation that replaced somebody's own configuration:
// theirs was moved aside, Chroma took the directory, and an update later left a
// generation beside it. Both of those are "a directory that was moved", and
// telling them apart is the whole of this milestone.
func takenOver(t *testing.T) (Paths, installstate.State, string) {
	t.Helper()

	paths, current := twoGenerations(t, []string{"terraform"})

	// The configuration that was there before Chroma. Real files, so that
	// removing it instead of restoring it is visible.
	userBackup := paths.ConfigDir + ".their-own-config"
	if err := os.MkdirAll(userBackup, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userBackup, "init.lua"), []byte("-- mine, not Chroma's\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	current.UserBackup = userBackup
	if err := installstate.Write(paths.InstallState, current); err != nil {
		t.Fatalf("Write: %v", err)
	}

	for _, dir := range []string{paths.DataDir, paths.CacheDir} {
		if err := os.MkdirAll(filepath.Join(dir, "lazy"), 0o755); err != nil {
			t.Fatal(err)
		}
	}

	return paths, current, userBackup
}

// The rule, stated as a test: what Chroma made it may remove, what Chroma
// borrowed it gives back.
func TestUninstallGivesBackWhatItBorrowedAndRemovesWhatItMade(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)
	generation := current.Previous.Path

	installer := &Installer{}
	removal, err := installer.Uninstall(paths, current)
	if err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	// Given back, at the place Chroma had taken.
	if removal.Restored != userBackup {
		t.Errorf("restored %q, want %q", removal.Restored, userBackup)
	}
	contents, err := os.ReadFile(filepath.Join(paths.ConfigDir, "init.lua"))
	if err != nil {
		t.Fatalf("the configuration that was here before Chroma is not back: %v", err)
	}
	if string(contents) != "-- mine, not Chroma's\n" {
		t.Errorf("%s holds %q, which is not what was moved aside", paths.ConfigDir, contents)
	}

	// And everything Chroma made is gone.
	for _, path := range []string{generation, paths.DataDir, paths.CacheDir, paths.SelectionFile, paths.StateDir} {
		if exists(path) {
			t.Errorf("%s is still there", path)
		}
	}
	if exists(paths.InstallState) {
		t.Error("the install record survived the uninstall")
	}
}

// The one thing that must never be on the removal list, checked on the plan so
// the failure is visible before anything runs.
func TestThePlanNeverRemovesTheUsersOwnConfiguration(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)

	plan := PlanUninstall(paths, current)
	for _, path := range plan.Remove {
		if path == userBackup {
			t.Fatalf("the plan removes %s, which belongs to the user", userBackup)
		}
	}
	if plan.Restore != userBackup {
		t.Errorf("restore = %q, want %q", plan.Restore, userBackup)
	}
}

// A Chroma generation is not a user backup, and is removed.
func TestAKeptGenerationIsRemoved(t *testing.T) {
	fixed(t)

	paths, current, _ := takenOver(t)
	generation := current.Previous.Path

	plan := PlanUninstall(paths, current)
	found := false
	for _, path := range plan.Remove {
		if path == generation {
			found = true
		}
	}
	if !found {
		t.Errorf("the kept generation %s is not removed; it is Chroma's own", generation)
	}
}

// An installation beside an existing configuration borrowed nothing, so there
// is nothing to give back and the directory simply goes.
func TestAnIsolatedInstallationRestoresNothing(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)

	installer := &Installer{}
	removal, err := installer.Uninstall(paths, current)
	if err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	if removal.Restored != "" {
		t.Errorf("restored %q, but nothing was ever moved aside", removal.Restored)
	}
	if exists(paths.ConfigDir) {
		t.Error("the configuration is still there")
	}
}

// The record goes last. Until it does, a second attempt still knows what was
// being managed.
func TestTheRecordIsRemovedLast(t *testing.T) {
	fixed(t)

	paths, current, _ := takenOver(t)

	plan := PlanUninstall(paths, current)
	if len(plan.Remove) == 0 {
		t.Fatal("the plan removes nothing")
	}
	if last := plan.Remove[len(plan.Remove)-1]; last != paths.StateDir {
		t.Errorf("the last thing removed is %q, want the state directory that holds install.json", last)
	}
}

// A restore that cannot happen puts Chroma back rather than leaving the
// directory empty, and deletes nothing.
func TestAFailedRestoreLeavesEverythingWhereItWas(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)

	// The backup is gone — somebody deleted it between installing and now.
	if err := os.RemoveAll(userBackup); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, current); err == nil {
		t.Fatal("an uninstall with nothing to restore reported success")
	}

	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("Chroma was not put back, so the directory is now empty")
	}
	for _, path := range []string{paths.DataDir, paths.CacheDir, paths.InstallState} {
		if !exists(path) {
			t.Errorf("%s was removed although the uninstall could not go ahead", path)
		}
	}
}
