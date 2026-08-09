package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// fixed makes the backup name predictable, which is the only part of it a test
// has any business knowing.
func fixed(t *testing.T) {
	t.Helper()
	saved := now
	now = func() time.Time { return time.Date(2026, 8, 9, 13, 42, 0, 0, time.UTC) }
	t.Cleanup(func() { now = saved })
}

// prepared builds a Chroma tree and hands back what Prepare would.
func prepared(t *testing.T) PreparedSource {
	t.Helper()

	root := tree(t)
	// Two things a checkout has and a release must not: the CLI's own module,
	// and the history.
	if err := os.MkdirAll(filepath.Join(root, "cli", "cmd"), 0o755); err != nil {
		t.Fatalf("creating cli: %v", err)
	}
	write(t, filepath.Join(root, "cli", "cmd", "main.go"), "package main\n")
	if err := os.MkdirAll(filepath.Join(root, ".git"), 0o755); err != nil {
		t.Fatalf("creating .git: %v", err)
	}
	write(t, filepath.Join(root, ".git", "HEAD"), "ref: refs/heads/main\n")
	if err := os.MkdirAll(filepath.Join(root, "lua", "chroma"), 0o755); err != nil {
		t.Fatalf("creating lua: %v", err)
	}
	write(t, filepath.Join(root, "lua", "chroma", "state.lua"), "return {}\n")

	source := LocalSource{Root: root}
	got, err := source.Prepare(context.Background())
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	return got
}

func target(t *testing.T) (*Transaction, Paths) {
	t.Helper()

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	return NewTransaction(paths), paths
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// Staging is a sibling of the target, or the rename that places it can cross a
// filesystem — and a cross-device rename is a copy, which is not atomic.
func TestStagingIsASiblingOfTheTarget(t *testing.T) {
	tx, paths := target(t)

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}

	if filepath.Dir(tx.StageDir) != filepath.Dir(paths.ConfigDir) {
		t.Errorf("staged at %s, want a sibling of %s", tx.StageDir, paths.ConfigDir)
	}
	if !exists(filepath.Join(tx.StageDir, "init.lua")) {
		t.Error("the staged tree has no init.lua")
	}
	if !exists(filepath.Join(tx.StageDir, "lua", "chroma", "state.lua")) {
		t.Error("the staged tree did not get lua/ recursively")
	}
	if !exists(filepath.Join(tx.StageDir, "components", "core.json")) {
		t.Error("the staged tree has no component contract")
	}
}

// What gets installed is the configuration, not the repository it lives in.
func TestStagingLeavesDevelopmentOutOfTheTree(t *testing.T) {
	tx, paths := target(t)

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}

	for _, entry := range []string{"cli", ".git"} {
		if exists(filepath.Join(tx.StageDir, entry)) {
			t.Errorf("%s was copied into the installation", entry)
		}
	}
}

// A configuration tree is copied rather than linked: following a symlink copies
// whatever it points at, and recreating one installs a path that means
// something else on the target machine.
func TestStagingRefusesASymlink(t *testing.T) {
	tx, paths := target(t)
	source := prepared(t)

	link := filepath.Join(source.Root, "lua", "elsewhere")
	if err := os.Symlink(filepath.Join(source.Root, "init.lua"), link); err != nil {
		t.Skipf("this filesystem will not take a symlink: %v", err)
	}

	err := tx.StageSource(source, paths)
	if err == nil {
		t.Fatal("staged a tree containing a symlink")
	}
	if !strings.Contains(err.Error(), "symlink") {
		t.Errorf("err = %v, want it to say what was wrong", err)
	}
}

func TestPlacementIsOneRename(t *testing.T) {
	tx, paths := target(t)

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	staged := tx.StageDir
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}

	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("nothing arrived at the target")
	}
	if exists(staged) {
		t.Error("the staging directory is still there after placement")
	}
	if !tx.Placed || tx.StageDir != "" {
		t.Errorf("the transaction did not record the placement: placed=%v stage=%q", tx.Placed, tx.StageDir)
	}
}

// The invariant this whole ordering exists for: there is no code path that
// removes an existing target. Place refuses instead.
func TestPlacementRefusesToOverwriteAnExistingTarget(t *testing.T) {
	tx, paths := target(t)

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- somebody else's\n")

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}

	err := tx.Place(paths)
	if err == nil {
		t.Fatal("placed a configuration over one that was already there")
	}
	if !strings.Contains(err.Error(), "moved aside") {
		t.Errorf("err = %v, want it to say what has to happen first", err)
	}
	if got := readFile(t, filepath.Join(paths.ConfigDir, "init.lua")); !strings.Contains(got, "somebody else") {
		t.Error("the existing configuration was touched")
	}
}

func TestBackupIsARenameToASibling(t *testing.T) {
	fixed(t)
	tx, paths := target(t)

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- the old one\n")

	if err := tx.BackupTarget(paths); err != nil {
		t.Fatalf("BackupTarget: %v", err)
	}

	want := filepath.Join(paths.BackupDir, filepath.Base(paths.ConfigDir)+".chroma-backup-20260809T134200Z")
	if tx.Backup != want {
		t.Errorf("backup at %s, want %s", tx.Backup, want)
	}
	if exists(paths.ConfigDir) {
		t.Error("the target is still there after being backed up")
	}
	if got := readFile(t, filepath.Join(tx.Backup, "init.lua")); !strings.Contains(got, "the old one") {
		t.Error("the backup does not hold what was there")
	}
}

// Two installations in the same second must not rename over each other's
// backup: it is the one file that cannot be recreated.
func TestASecondBackupInTheSameSecondDoesNotReplaceTheFirst(t *testing.T) {
	fixed(t)
	tx, paths := target(t)

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- the first\n")
	if err := tx.BackupTarget(paths); err != nil {
		t.Fatalf("first BackupTarget: %v", err)
	}
	first := tx.Backup

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("recreating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- the second\n")
	second := NewTransaction(paths)
	if err := second.BackupTarget(paths); err != nil {
		t.Fatalf("second BackupTarget: %v", err)
	}

	if second.Backup == first {
		t.Fatal("the second backup replaced the first")
	}
	if got := readFile(t, filepath.Join(first, "init.lua")); !strings.Contains(got, "the first") {
		t.Error("the first backup was overwritten")
	}
}

// The failure that matters: everything worked up to placement, and then
// something after it did not.
func TestRollbackAfterPlacementPutsTheOldConfigurationBack(t *testing.T) {
	fixed(t)
	tx, paths := target(t)

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- the old one\n")

	if err := tx.WriteSelection([]string{"terraform"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.BackupTarget(paths); err != nil {
		t.Fatalf("BackupTarget: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}

	// Something after placement fails — bootstrap, verify, the state write.
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if got := readFile(t, filepath.Join(paths.ConfigDir, "init.lua")); !strings.Contains(got, "the old one") {
		t.Errorf("the previous configuration did not come back: %q", got)
	}
	if exists(tx.Backup) {
		t.Error("the backup is still lying about after being restored")
	}
	if _, err := os.Stat(paths.SelectionFile); !os.IsNotExist(err) {
		t.Error("the selection survived a rolled-back install")
	}
}

// Rollback runs when something has already gone wrong, so it has to survive
// being run again.
func TestRollbackAfterPlacementIsIdempotent(t *testing.T) {
	fixed(t)
	tx, paths := target(t)

	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- the old one\n")

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.BackupTarget(paths); err != nil {
		t.Fatalf("BackupTarget: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}

	for i := 0; i < 3; i++ {
		if err := tx.Rollback(); err != nil {
			t.Fatalf("Rollback %d: %v", i, err)
		}
	}
	if got := readFile(t, filepath.Join(paths.ConfigDir, "init.lua")); !strings.Contains(got, "the old one") {
		t.Errorf("repeated rollbacks did not leave the old configuration: %q", got)
	}
}

// A first install has nothing to put back, so rollback removes what it placed
// and leaves the machine as it found it.
func TestRollbackOfAFirstInstallLeavesNothingBehind(t *testing.T) {
	tx, paths := target(t)

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if exists(paths.ConfigDir) {
		t.Error("a rolled-back first install left a configuration behind")
	}
}

// Cleanup is not a rollback and must never behave like one.
func TestCleanupRemovesOnlyStaging(t *testing.T) {
	tx, paths := target(t)

	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}
	tx.Commit()
	if err := tx.Cleanup(); err != nil {
		t.Fatalf("Cleanup: %v", err)
	}

	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("cleanup removed the installation")
	}
}

func TestTargetPolicy(t *testing.T) {
	t.Run("an empty target is an ordinary install", func(t *testing.T) {
		_, paths := target(t)
		needsBackup, err := CheckTarget(paths)
		if err != nil || needsBackup {
			t.Errorf("CheckTarget = %v, %v; want false, nil", needsBackup, err)
		}
	})

	t.Run("a managed installation is an update", func(t *testing.T) {
		_, paths := target(t)
		if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
			t.Fatalf("creating the target: %v", err)
		}
		if err := os.MkdirAll(filepath.Dir(paths.InstallState), 0o755); err != nil {
			t.Fatalf("creating the state directory: %v", err)
		}
		write(t, paths.InstallState, "{}\n")

		_, err := CheckTarget(paths)
		if err == nil || !strings.Contains(err.Error(), "chroma update") {
			t.Errorf("err = %v, want it to point at update", err)
		}
	})

	t.Run("an unmanaged directory under our own name is a surprise", func(t *testing.T) {
		_, paths := target(t)
		if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
			t.Fatalf("creating the target: %v", err)
		}

		_, err := CheckTarget(paths)
		if err == nil || !strings.Contains(err.Error(), "move it aside") {
			t.Errorf("err = %v, want a refusal", err)
		}
	})

	t.Run("Neovim's own directory is backed up rather than refused", func(t *testing.T) {
		xdg(t, t.TempDir())
		paths, err := ResolvePaths(true)
		if err != nil {
			t.Fatalf("ResolvePaths: %v", err)
		}
		if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
			t.Fatalf("creating the target: %v", err)
		}

		needsBackup, err := CheckTarget(paths)
		if err != nil {
			t.Fatalf("CheckTarget: %v", err)
		}
		if !needsBackup {
			t.Error("taking over an existing Neovim configuration without a backup")
		}
	})
}
