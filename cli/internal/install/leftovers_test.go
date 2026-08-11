package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// used is a machine somebody has been running Neovim on, without ever having a
// configuration of their own: no `~/.config/nvim`, but data, state and cache
// full of what the editor left there. That is the shape a real takeover
// reported —
//
//	backup: data:  ~/.local/share/nvim.chroma-backup-…
//	backup: state: ~/.local/state/nvim.chroma-backup-…
//	backup: cache: ~/.cache/nvim.chroma-backup-…
//
// with no configuration line, and it is the one the fixtures did not have.
func used(t *testing.T) Paths {
	t.Helper()

	xdg(t, t.TempDir())

	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	for _, dir := range []string{paths.DataDir, paths.StateDir, paths.CacheDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "mine.txt"), []byte("the user's own\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	return paths
}

// asides names every directory Chroma has moved aside and not yet given back.
func asides(t *testing.T, paths Paths) []string {
	t.Helper()

	var found []string
	for _, dir := range []string{
		filepath.Dir(paths.ConfigDir),
		filepath.Dir(paths.DataDir),
		filepath.Dir(paths.StateDir),
		filepath.Dir(paths.CacheDir),
	} {
		entries, err := os.ReadDir(dir)
		if err != nil {
			continue
		}
		for _, entry := range entries {
			if strings.Contains(entry.Name(), ".chroma-backup-") {
				found = append(found, filepath.Join(dir, entry.Name()))
			}
		}
	}
	return found
}

// Installing, uninstalling and installing again has to leave a machine that
// looks like the one before the first install — and in particular no record,
// because a leftover install.json is what makes the next `chroma install`
// refuse, saying the machine already has one.
//
// Reported from a real machine: after an uninstall the record was still at
// ~/.local/state/nvim/install.json, the next install would not start, and the
// backups of the first install were still sitting beside the directories they
// had been taken from.
func TestInstallUninstallInstallLeavesNothingBehind(t *testing.T) {
	fixed(t)

	paths := used(t)
	source, contract := prepared(t), shipped(t)
	installer := &Installer{Runner: &failAt{}}

	first, err := installer.Apply(context.Background(), Options{UseDefault: true, Selected: []string{}}, paths, source, contract)
	if err != nil {
		t.Fatalf("the first installation failed: %v", err)
	}
	if len(first.State.Borrowed) != 3 {
		t.Fatalf("borrowed %d directories, want data, state and cache", len(first.State.Borrowed))
	}

	removal, err := installer.Uninstall(paths, first.State)
	if err != nil {
		t.Fatalf("the uninstall failed: %v (%v)", err, removal.Problems)
	}

	// The record is the one thing whose absence the next install depends on.
	if _, err := os.Lstat(paths.InstallState); !os.IsNotExist(err) {
		t.Errorf("%s is still there after the uninstall", paths.InstallState)
	}
	if left := asides(t, paths); len(left) > 0 {
		t.Errorf("the uninstall left %d directory of its own aside: %v", len(left), left)
	}
	for _, dir := range []string{paths.DataDir, paths.StateDir, paths.CacheDir} {
		if _, err := os.ReadFile(filepath.Join(dir, "mine.txt")); err != nil {
			t.Errorf("what was borrowed is not back at %s: %v", dir, err)
		}
	}

	// And the machine can be installed onto again, which is the whole point.
	second, err := installer.Apply(context.Background(), Options{UseDefault: true, Selected: []string{}}, paths, prepared(t), contract)
	if err != nil {
		t.Fatalf("the second installation failed: %v", err)
	}

	if _, err := installer.Uninstall(paths, second.State); err != nil {
		t.Fatalf("the second uninstall failed: %v", err)
	}
	if left := asides(t, paths); len(left) > 0 {
		t.Errorf("after the second round %d directory is still aside: %v", len(left), left)
	}
}

// The same loop, as the CLI sees it: what `recorded` finds is what refuses a
// second installation, and after an uninstall it must find nothing.
func TestNothingIsRecordedAfterAnUninstall(t *testing.T) {
	fixed(t)

	paths := used(t)
	installer := &Installer{Runner: &failAt{}}

	result, err := installer.Apply(context.Background(), Options{UseDefault: true, Selected: []string{}}, paths, prepared(t), shipped(t))
	if err != nil {
		t.Fatalf("the installation failed: %v", err)
	}
	if _, found, err := installstate.Load(paths.InstallState); err != nil || !found {
		t.Fatalf("the installation recorded nothing: found=%v err=%v", found, err)
	}

	if _, err := installer.Uninstall(paths, result.State); err != nil {
		t.Fatalf("the uninstall failed: %v", err)
	}

	if _, found, err := installstate.Load(paths.InstallState); found || err != nil {
		t.Errorf("the record survived the uninstall, so the next install will refuse: found=%v err=%v", found, err)
	}
}
