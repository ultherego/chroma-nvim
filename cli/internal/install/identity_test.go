package install

import (
	"os"
	"path/filepath"
	"testing"
)

// The property the whole ownership model rests on, asserted about whatever
// filesystem this is running on rather than about the one it was written on.
//
// It has to hold both ways. Identity must survive a rename, because every move
// Chroma makes is one. And it must not survive a directory being deleted and
// another created in its place, because that is the substitution the proof
// exists to refuse.
//
// The second half was measured to fail with device and inode alone. A
// filesystem may hand the new directory the inode of the deleted one, and on
// ext4 it does so every time:
//
//	btrfs, tmpfs, overlayfs   0/40 rounds reused the inode
//	ext4 (the CI runner)     40/40 rounds reused the inode
//
// So this test passed on the machine it was written on and failed on CI, which
// is the only reason it was found. Written this way it fails on either.
func TestIdentitySurvivesARenameAndNotAReplacement(t *testing.T) {
	root := t.TempDir()

	build := func(dir, contents string) {
		if err := os.MkdirAll(filepath.Join(dir, "lua", "mine"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "init.lua"), []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	identify := func(dir string) Identity {
		t.Helper()
		identity, err := Identify(dir)
		if err != nil {
			t.Fatal(err)
		}
		return identity
	}

	// Enough rounds that a filesystem which only sometimes reuses an inode is
	// not passed by luck.
	const rounds = 40
	for round := 0; round < rounds; round++ {
		here := filepath.Join(root, "theirs")
		build(here, "mine, not Chroma's")
		taken := identify(here)

		aside := filepath.Join(root, "theirs.chroma-backup")
		if err := os.Rename(here, aside); err != nil {
			t.Fatal(err)
		}
		if moved := identify(aside); moved != taken {
			t.Fatalf("round %d: a rename changed the identity: %+v became %+v", round, taken, moved)
		}

		if err := os.RemoveAll(aside); err != nil {
			t.Fatal(err)
		}
		build(aside, "somebody else's")
		if substitute := identify(aside); substitute == taken {
			t.Fatalf("round %d: a directory created where the borrowed one was deleted has the same identity %+v, so a substitution cannot be refused on this filesystem", round, taken)
		}

		if err := os.RemoveAll(aside); err != nil {
			t.Fatal(err)
		}
	}
}
