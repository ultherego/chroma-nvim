package atomicfile

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

// The docstring says a failure at any point leaves the original file exactly as
// it was. Three of the steps happen after the rename.
func TestAFailureAfterTheRenameLeavesTheNewContents(t *testing.T) {
	path := filepath.Join(t.TempDir(), "install.json")
	if err := os.WriteFile(path, []byte("OLD"), 0o644); err != nil {
		t.Fatal(err)
	}

	stopped := errors.New("the directory could not be flushed")
	AfterRename = func(string) error { return stopped }
	t.Cleanup(func() { AfterRename = nil })

	_, err := Replace(path, []byte("NEW"), 0o644)

	if !errors.Is(err, stopped) {
		t.Fatalf("err = %v, want the failure to surface", err)
	}

	contents, readErr := os.ReadFile(path)
	if readErr != nil {
		t.Fatal(readErr)
	}
	if string(contents) == "OLD" {
		t.Fatal("the original survived, so this window does not exist")
	}
	t.Logf("Replace returned an error and the file holds %q — the caller is told nothing happened", contents)
}
