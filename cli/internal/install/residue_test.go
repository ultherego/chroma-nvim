package install

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// unremovable makes one directory impossible to delete, by taking the write bit
// off the directory that holds it. The entry cannot be unlinked, so RemoveAll
// fails on it and on nothing else.
func unremovable(t *testing.T, dir string) {
	t.Helper()

	if os.Geteuid() == 0 {
		t.Skip("running as root, which is not stopped by a permission bit")
	}

	parent := filepath.Dir(dir)
	before, err := os.Stat(parent)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(parent, 0o555); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(parent, before.Mode()) })
}

// **Point 10A.** An isolated installation whose data directory cannot be
// removed. The question is whether the record — the only map of what is left to
// clean up — survives the failure.
func TestAnIsolatedUninstallKeepsItsRecordWhenCleanupFails(t *testing.T) {
	fixed(t)

	paths, record := installed(t, nil)
	for _, dir := range []string{paths.DataDir, paths.CacheDir} {
		put(t, filepath.Join(dir, "something"), "chroma's own\n")
	}
	unremovable(t, paths.DataDir)

	installer := &Installer{}
	_, err := installer.Uninstall(paths, record)
	if err == nil {
		t.Fatal("the uninstall reported success although a removal could not happen")
	}

	if !exists(paths.DataDir) {
		t.Fatal("the data directory was removed after all, so this measures nothing")
	}

	t.Logf("data directory left behind: %v", exists(paths.DataDir))
	t.Logf("state directory still there: %v", exists(paths.StateDir))
	t.Logf("record still there:          %v", exists(paths.InstallState))

	if !exists(paths.InstallState) {
		t.Error("the record is gone while Chroma's own data directory is still there: nothing left can say what to finish")
	}
}

// **Point 10B.** A takeover where a Chroma-owned directory cannot be cleaned up
// before the borrowed state directory is handed back.
//
// State is the terminal resource: install.json lives under it, so handing it
// back is the moment Chroma loses the record. Doing that while an earlier
// obligation has failed is the same fault as 10A, in the shape schema 6 gives
// it.
func TestATakeoverDoesNotHandBackStateWhileCleanupIsUnfinished(t *testing.T) {
	fixed(t)

	paths := neovims(t, t.TempDir())
	theirs(t, paths)
	record := takeoverOver(t, paths)

	if len(record.Borrowed) != 4 {
		t.Fatalf("borrowed %d, want 4", len(record.Borrowed))
	}

	// Chroma's own directories, as a bootstrap would leave them.
	for _, dir := range []string{paths.DataDir, paths.CacheDir, paths.StateDir} {
		put(t, filepath.Join(dir, "chroma-put-this-here"), "not the user's\n")
	}

	// The cache cannot be moved out of the way, so its hand-back fails.
	unremovable(t, paths.CacheDir)

	installer := &Installer{}
	_, err := installer.Uninstall(paths, record)

	t.Logf("uninstall failed:            %v", err != nil)
	t.Logf("record still there:          %v", exists(paths.InstallState))
	t.Logf("user's cache back:           %v", !exists(borrowedBackup(record, "cache")))
	t.Logf("user's state back:           %v", !exists(borrowedBackup(record, "state")))

	if err == nil {
		t.Error("the uninstall reported success although the cache could not be handed back")
	}
	if !exists(paths.InstallState) {
		t.Error("the record is gone while a borrowed directory is still owed: a second run cannot finish what this one started")
	}
	if exists(borrowedBackup(record, "cache")) && !exists(borrowedBackup(record, "state")) {
		t.Error("the state directory was handed back while the cache was still owed, which is the order that loses the record")
	}
}

// reload reads the record back, which is the whole point of keeping it.
func reload(t *testing.T, paths Paths) installstate.State {
	t.Helper()

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("the record a second run needs is unreadable: %v found=%v", err, found)
	}
	return record
}

// The other half of 10A: once whatever stopped the removal is out of the way, a
// second run finishes what the first one started.
func TestASecondUninstallFinishesWhatTheFirstCouldNot(t *testing.T) {
	fixed(t)

	paths, record := installed(t, nil)
	for _, dir := range []string{paths.DataDir, paths.CacheDir} {
		put(t, filepath.Join(dir, "something"), "chroma's own\n")
	}

	parent := filepath.Dir(paths.DataDir)
	before, err := os.Stat(parent)
	if err != nil {
		t.Fatal(err)
	}
	unremovable(t, paths.DataDir)

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, record); err == nil {
		t.Fatal("the first run reported success")
	}

	// Whatever was in the way is gone now — a full disk emptied, a permission
	// restored, a file no longer open.
	if err := os.Chmod(parent, before.Mode()); err != nil {
		t.Fatal(err)
	}

	if _, err := installer.Uninstall(paths, reload(t, paths)); err != nil {
		t.Fatalf("the second run could not finish: %v", err)
	}

	for _, path := range []string{paths.DataDir, paths.CacheDir, paths.StateDir, paths.InstallState, paths.ConfigDir} {
		if exists(path) {
			t.Errorf("%s is still there after the second run", path)
		}
	}
}

// **The most important regression after schema 6.** A takeover that stops
// partway leaves some directories handed back and some still owed, and a second
// run must finish exactly the rest: not touch what has already gone home, and
// not leave the record behind when it is done.
func TestASecondUninstallFinishesATakeoverWithoutTouchingWhatWentHome(t *testing.T) {
	fixed(t)

	paths := neovims(t, t.TempDir())
	homes := theirs(t, paths)
	before := map[string]map[string]string{}
	for _, home := range homes {
		before[home] = manifest(t, home)
	}

	record := takeoverOver(t, paths)
	for _, dir := range []string{paths.DataDir, paths.CacheDir, paths.StateDir} {
		put(t, filepath.Join(dir, "chroma-put-this-here"), "not the user's\n")
	}

	parent := filepath.Dir(paths.CacheDir)
	mode, err := os.Stat(parent)
	if err != nil {
		t.Fatal(err)
	}
	unremovable(t, paths.CacheDir)

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, record); err == nil {
		t.Fatal("the first run reported success although the cache could not be handed back")
	}

	// What the record has to say at this point: the configuration and the data
	// are somebody else's again, the cache and the state are still owed.
	stopped := reload(t, paths)
	for _, one := range stopped.Borrowed {
		switch one.Kind {
		case "configuration", "data":
			if one.Handover != installstate.HandoverHandedBack {
				t.Errorf("your %s went home but the record says %q", one.Kind, one.Handover)
			}
		case "cache", "state":
			if one.Handover == installstate.HandoverHandedBack {
				t.Errorf("your %s is still at %s but the record says it was given back", one.Kind, one.Backup)
			}
		}
	}

	// The two that went home are not moved again by the second run, which is
	// what "ownership does not come back" means in practice.
	returned := map[string]map[string]string{}
	for _, home := range []string{paths.ConfigDir, paths.DataDir} {
		returned[home] = manifest(t, home)
	}

	if err := os.Chmod(parent, mode.Mode()); err != nil {
		t.Fatal(err)
	}
	if _, err := installer.Uninstall(paths, stopped); err != nil {
		t.Fatalf("the second run could not finish: %v", err)
	}

	for home, was := range returned {
		compare(t, home+" (already handed back)", was, manifest(t, home))
	}
	for _, home := range homes {
		compare(t, home, before[home], manifest(t, home))
	}
	if exists(paths.InstallState) {
		t.Error("the record is still there after a finished uninstall")
	}
}

// And the ordinary case: everything works, and the record disappears at the very
// end rather than somewhere in the middle.
func TestAFinishedUninstallRemovesTheRecordLast(t *testing.T) {
	fixed(t)

	paths, record := installed(t, nil)
	for _, dir := range []string{paths.DataDir, paths.CacheDir} {
		put(t, filepath.Join(dir, "something"), "chroma's own\n")
	}

	installer := &Installer{}
	removal, err := installer.Uninstall(paths, record)
	if err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	if last := removal.Removed[len(removal.Removed)-1]; last != paths.StateDir {
		t.Errorf("the last thing removed was %s, want the state directory %s", last, paths.StateDir)
	}
	for _, path := range []string{paths.StateDir, paths.InstallState} {
		if exists(path) {
			t.Errorf("%s survived a finished uninstall", path)
		}
	}
}
