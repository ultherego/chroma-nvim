package install

import (
	"context"
	"os"
	"path/filepath"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// H6, ownership: recovery checks that an orphan looks like a Chroma tree, and
// that check follows symlinks. Every other use of a path from the record is
// guarded by RefuseSubstituted; this one was not.
func TestRecoveryRefusesAnOrphanThatIsALink(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)
	mark(t, paths.ConfigDir, "committed")

	// A directory of somebody's that happens to look like a configuration.
	theirs := filepath.Join(t.TempDir(), "theirs")
	if err := os.MkdirAll(filepath.Join(theirs, "lua", "chroma"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(theirs, "lua", "chroma", "bootstrap.lua"), "return {}\n")
	write(t, filepath.Join(theirs, "init.lua"), "-- theirs\n")

	// The arrangement of an interrupted update: the target gone, and beside it
	// something with a backup's name — which is a link.
	if err := os.RemoveAll(paths.ConfigDir); err != nil {
		t.Fatal(err)
	}
	orphan := paths.ConfigDir + backupMark + "20260810T000000Z"
	if err := os.Symlink(theirs, orphan); err != nil {
		t.Fatal(err)
	}

	if _, err := Recover(paths, current); err == nil {
		t.Error("a symbolic link was restored as the committed generation")
	}

	if target, err := os.Readlink(orphan); err != nil || target != theirs {
		t.Errorf("the link was moved: %q %v", target, err)
	}
	if !exists(filepath.Join(theirs, "init.lua")) {
		t.Error("what the link pointed at is gone")
	}
}

// H6, ownership: taking over a directory that is a symbolic link records the
// link as the configuration Chroma is holding. Uninstall then refuses to hand a
// link back — correctly — which leaves an installation whose own uninstall
// cannot finish.
func TestTakingOverALinkedDirectoryIsRefused(t *testing.T) {
	fixed(t)

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatal(err)
	}

	theirs := filepath.Join(t.TempDir(), "their-checkout")
	if err := os.MkdirAll(theirs, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(theirs, "init.lua"), "-- a checkout somewhere else\n")

	if err := os.MkdirAll(filepath.Dir(paths.ConfigDir), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(theirs, paths.ConfigDir); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	_, err = installer.Apply(context.Background(), Options{UseDefault: true, Selected: nil}, paths, prepared(t), shipped(t))
	if err == nil {
		t.Fatal("Chroma took over a directory that was a link")
	}

	if target, readErr := os.Readlink(paths.ConfigDir); readErr != nil || target != theirs {
		t.Errorf("the link was moved aside: %q %v", target, readErr)
	}
	if _, found, _ := installstate.Load(paths.InstallState); found {
		t.Error("an installation was recorded despite the refusal")
	}
}

// Audit finding 3: a directory is removed because its name matches a pattern.
//
// The topology is complete — nothing interrupted, nothing missing — so recovery
// has no work. It sweeps anyway, by name, and there is no evidence that this
// particular inode was made by a Chroma recovery rather than by whoever owns the
// account.
func TestACleanupNeverRemovesADirectoryItDidNotCreate(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)

	theirs := paths.ConfigDir + provisionalMark + "OWNED-BY-USER"
	if err := os.MkdirAll(theirs, 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(theirs, "DO_NOT_DELETE"), "mine\n")

	if _, err := Recover(paths, current); err != nil {
		t.Fatalf("Recover: %v", err)
	}

	if !exists(filepath.Join(theirs, "DO_NOT_DELETE")) {
		t.Error("a directory nobody proved was Chroma's was removed because its name matched")
	}
}
