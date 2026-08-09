package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// shipped is the contract this repository actually ships, so a selection these
// tests write is one the editor beside them would accept.
func shipped(t *testing.T) component.Set {
	t.Helper()

	set, problems, err := component.Load(filepath.Join("..", "..", "..", "components"))
	if err != nil || len(problems) > 0 {
		t.Fatalf("loading the shipped contract: %v %v", err, problems)
	}
	return set
}

func newTransaction(t *testing.T) (*Transaction, Paths) {
	t.Helper()

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	return NewTransaction(paths), paths
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	contents, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v", path, err)
	}
	return string(contents)
}

func TestSelectionIsWrittenAndCommitted(t *testing.T) {
	tx, paths := newTransaction(t)

	if err := tx.WriteSelection([]string{"terraform", "vault"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	tx.Commit()

	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback after Commit: %v", err)
	}

	written := readFile(t, paths.SelectionFile)
	for _, id := range []string{"terraform", "vault"} {
		if !strings.Contains(written, id) {
			t.Errorf("the committed selection does not contain %q: %s", id, written)
		}
	}
}

// The migration promise, at install time: a machine that had no selection and a
// failed install still has no selection. Leaving one behind would be the
// installer inventing a choice nobody made — and the editor reads an absent
// file as "run everything", so the invented file would switch components off.
func TestAFailedInstallLeavesNoSelectionWhereThereWasNone(t *testing.T) {
	tx, paths := newTransaction(t)

	if err := tx.WriteSelection([]string{"terraform"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	if _, err := os.Stat(paths.SelectionFile); err != nil {
		t.Fatalf("nothing was written: %v", err)
	}

	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if _, err := os.Stat(paths.SelectionFile); !os.IsNotExist(err) {
		t.Errorf("a selection survived a rolled-back install: %v", err)
	}
}

func TestAFailedInstallPutsBackTheSelectionThatWasThere(t *testing.T) {
	tx, paths := newTransaction(t)

	before := `{ "schema": 1, "selected": ["vault"] }` + "\n"
	if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
		t.Fatalf("creating the selection directory: %v", err)
	}
	if err := os.WriteFile(paths.SelectionFile, []byte(before), 0o644); err != nil {
		t.Fatalf("writing the previous selection: %v", err)
	}

	if err := tx.WriteSelection([]string{"terraform", "kubernetes"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	if got := readFile(t, paths.SelectionFile); strings.Contains(got, "vault") {
		t.Fatalf("the new selection was not written: %s", got)
	}

	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	// Byte for byte, not "an equivalent selection": what was there is not the
	// installer's to reformat.
	if got := readFile(t, paths.SelectionFile); got != before {
		t.Errorf("restored %q, want %q", got, before)
	}
}

// The case that decides whether the restore validates: a file that was already
// invalid is still not the installer's to correct. Rewriting it would mean an
// install that failed silently changed a document it never owned.
func TestRollbackRestoresEvenAnInvalidSelection(t *testing.T) {
	tx, paths := newTransaction(t)

	before := "{ this was already broken\n"
	if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
		t.Fatalf("creating the selection directory: %v", err)
	}
	if err := os.WriteFile(paths.SelectionFile, []byte(before), 0o644); err != nil {
		t.Fatalf("writing the previous selection: %v", err)
	}

	if err := tx.WriteSelection([]string{"aws"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if got := readFile(t, paths.SelectionFile); got != before {
		t.Errorf("restored %q, want the broken file back exactly: %q", got, before)
	}
}

// Rollback runs when something has already gone wrong, so it has to survive
// being called twice — and doing nothing before anything happened.
func TestRollbackIsIdempotentAndSafeBeforeAnythingHappens(t *testing.T) {
	tx, paths := newTransaction(t)

	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback before anything: %v", err)
	}

	if err := tx.WriteSelection([]string{"docker"}, shipped(t)); err != nil {
		t.Fatalf("WriteSelection: %v", err)
	}
	for i := 0; i < 3; i++ {
		if err := tx.Rollback(); err != nil {
			t.Fatalf("Rollback %d: %v", i, err)
		}
	}

	if _, err := os.Stat(paths.SelectionFile); !os.IsNotExist(err) {
		t.Errorf("the selection is back after repeated rollbacks: %v", err)
	}
}

// The writer refuses what the reader would refuse, and a refused write is not
// something to roll back: nothing happened.
func TestARefusedSelectionChangesNothing(t *testing.T) {
	tx, paths := newTransaction(t)

	before := `{ "schema": 1, "selected": ["vault"] }` + "\n"
	if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
		t.Fatalf("creating the selection directory: %v", err)
	}
	if err := os.WriteFile(paths.SelectionFile, []byte(before), 0o644); err != nil {
		t.Fatalf("writing the previous selection: %v", err)
	}

	if err := tx.WriteSelection([]string{"magic"}, shipped(t)); err == nil {
		t.Fatal("wrote a selection naming a component that does not exist")
	}

	if got := readFile(t, paths.SelectionFile); got != before {
		t.Errorf("a refused write changed the file: %q", got)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}
	if got := readFile(t, paths.SelectionFile); got != before {
		t.Errorf("rollback after a refused write changed the file: %q", got)
	}
}
