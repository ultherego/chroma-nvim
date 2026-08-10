package main

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// The log directory sits under the state directory, and on a `--default`
// installation the state directory is still somebody else's when the runner is
// built. Creating it then put a Chroma log inside the user's own
// `~/.local/state/nvim`, which the takeover moved aside with the log in it and
// the uninstall handed back with the log still there — found by comparing the
// four directories byte for byte after a real bootstrap, because nothing
// failed and nothing was lost.
func TestTheLogIsNotOpenedUntilSomethingIsWrittenToIt(t *testing.T) {
	root := t.TempDir()
	paths := install.Paths{LogDir: filepath.Join(root, "state", "nvim", "logs")}

	log := logFile(paths, os.Stderr)

	if _, err := os.Stat(filepath.Dir(paths.LogDir)); err == nil {
		t.Fatalf("%s was created before anything was logged", filepath.Dir(paths.LogDir))
	}

	if _, err := log.Write([]byte("the editor said something\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}

	entries, err := os.ReadDir(paths.LogDir)
	if err != nil {
		t.Fatalf("nothing was written once there was something to write: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("the log directory holds %d files, want 1", len(entries))
	}
}

// A run with nowhere to log still installs.
func TestARunWithNowhereToLogDoesNotFail(t *testing.T) {
	blocked := filepath.Join(t.TempDir(), "not-a-directory")
	if err := os.WriteFile(blocked, []byte("in the way\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	quiet, err := os.OpenFile(os.DevNull, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer quiet.Close()

	log := logFile(install.Paths{LogDir: filepath.Join(blocked, "logs")}, quiet)
	if _, err := log.Write([]byte("nowhere to put this\n")); err != nil {
		t.Errorf("a log that could not be opened failed the write: %v", err)
	}
}
