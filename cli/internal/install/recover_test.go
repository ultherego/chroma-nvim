package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// interrupted builds, by hand, the arrangement a kill leaves behind. Doing it
// by hand rather than by killing a process keeps these tests fast and lets them
// state the shape they are about; the shapes themselves came from real SIGKILLs
// in crash_test.go.
func interrupted(t *testing.T, targetHolds, orphanHolds string) (Paths, installstate.State) {
	t.Helper()

	paths, current := installed(t, nil)
	mark(t, paths.ConfigDir, "committed")

	orphan := paths.ConfigDir + backupMark + "20260810T000000Z"
	if err := os.Rename(paths.ConfigDir, orphan); err != nil {
		t.Fatal(err)
	}
	mark(t, orphan, orphanHolds)

	if targetHolds != "" {
		if err := os.MkdirAll(filepath.Join(paths.ConfigDir, "lua", "chroma"), 0o755); err != nil {
			t.Fatal(err)
		}
		write(t, filepath.Join(paths.ConfigDir, "lua", "chroma", "bootstrap.lua"), "return {}\n")
		write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- provisional\n")
		mark(t, paths.ConfigDir, targetHolds)
	}

	return paths, current
}

func held(t *testing.T, dir string) string {
	t.Helper()

	contents, err := os.ReadFile(filepath.Join(dir, "README.md"))
	if err != nil {
		return "<nothing>"
	}
	return string(contents)
}

// An update killed after the backup: the target is empty and the committed
// generation is beside it.
func TestRecoveryPutsBackACommittedGenerationWithAnEmptyTarget(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "", "v1")

	why, err := Recover(paths, current)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if why == "" {
		t.Fatal("nothing was recovered and nothing was said")
	}

	if got := held(t, paths.ConfigDir); got != "v1" {
		t.Errorf("the target holds %q, want the committed v1", got)
	}
	if beside := backupsBeside(t, paths); len(beside) != 0 {
		t.Errorf("an orphaned backup is still there: %v", beside)
	}
}

// An update killed after the place: the target holds a generation nothing ever
// recorded, and the committed one is beside it. The record wins.
func TestRecoveryPrefersTheCommittedGenerationOverAnUncommittedOne(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2-uncommitted", "v1")

	if _, err := Recover(paths, current); err != nil {
		t.Fatalf("Recover: %v", err)
	}

	if got := held(t, paths.ConfigDir); got != "v1" {
		t.Errorf("the target holds %q, want the committed v1", got)
	}

	// The uncommitted tree is gone, and so is any trace of the recovery.
	entries, err := os.ReadDir(filepath.Dir(paths.ConfigDir))
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Base(paths.ConfigDir)
	for _, entry := range entries {
		if entry.Name() != base && strings.HasPrefix(entry.Name(), base) {
			t.Errorf("%s was left behind", entry.Name())
		}
	}
}

// An interrupted rollback: the record describes the arrangement before the
// swap, and recovery undoes the swap rather than completing it.
func TestRecoveryUndoesAnInterruptedRollback(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	previousPath := current.Previous.Path
	mark(t, paths.ConfigDir, "v2")
	mark(t, previousPath, "v1")

	// The state a kill after the swap leaves: previous moved into the target,
	// what was current moved to a fresh backup nothing references.
	orphan := paths.ConfigDir + backupMark + "20260810T111111Z"
	if err := os.Rename(paths.ConfigDir, orphan); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(previousPath, paths.ConfigDir); err != nil {
		t.Fatal(err)
	}

	why, err := Recover(paths, current)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if !strings.Contains(why, "rollback") {
		t.Errorf("the explanation does not say what it found: %q", why)
	}

	if got := held(t, paths.ConfigDir); got != "v2" {
		t.Errorf("the target holds %q, want v2 — the record's current", got)
	}
	if got := held(t, previousPath); got != "v1" {
		t.Errorf("%s holds %q, want v1 back where the record says it is", previousPath, got)
	}
}

// Nothing to recover is not an error, and is silent.
func TestRecoveryOfACommittedInstallationDoesNothing(t *testing.T) {
	fixed(t)

	paths, current := installed(t, nil)
	mark(t, paths.ConfigDir, "v1")

	why, err := Recover(paths, current)
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if why != "" {
		t.Errorf("a committed installation was reported as interrupted: %q", why)
	}
	if got := held(t, paths.ConfigDir); got != "v1" {
		t.Errorf("the target holds %q, want it untouched", got)
	}
}

// Two orphans is not a puzzle to solve. Nothing moves.
func TestTwoOrphansAreRefusedRatherThanGuessedBetween(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2", "v1")
	second := paths.ConfigDir + backupMark + "20260810T222222Z"
	if err := os.MkdirAll(filepath.Join(second, "lua", "chroma"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(second, "lua", "chroma", "bootstrap.lua"), "return {}\n")

	before := held(t, paths.ConfigDir)

	if _, err := Recover(paths, current); err == nil {
		t.Fatal("two unreferenced backups were reconciled anyway")
	}
	if got := held(t, paths.ConfigDir); got != before {
		t.Errorf("the target changed to %q despite the refusal", got)
	}
	if !exists(second) {
		t.Error("a directory was removed despite the refusal")
	}
}

// An orphan that is not a Chroma tree proves nothing.
func TestAnOrphanThatIsNotAChromaTreeIsRefused(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2", "v1")
	orphan := backupsBeside(t, paths)[0]
	if err := os.RemoveAll(filepath.Join(orphan, "lua")); err != nil {
		t.Fatal(err)
	}

	if _, err := Recover(paths, current); err == nil {
		t.Error("a directory that is not a Chroma configuration was restored as one")
	}
	if got := held(t, paths.ConfigDir); got != "v2" {
		t.Errorf("the target changed to %q despite the refusal", got)
	}
}

// Recovery is itself interruptible, so it has to be safe to run again. This is
// the state a kill between its first and second rename leaves.
func TestRecoveryIsRetryable(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2-uncommitted", "v1")

	// Step one of Repair, and then nothing.
	aside := paths.ConfigDir + provisionalMark + "20260810T333333Z"
	if err := os.Rename(paths.ConfigDir, aside); err != nil {
		t.Fatal(err)
	}

	why, err := Recover(paths, current)
	if err != nil {
		t.Fatalf("the second attempt failed: %v", err)
	}
	if why == "" {
		t.Fatal("the second attempt found nothing to do")
	}

	if got := held(t, paths.ConfigDir); got != "v1" {
		t.Errorf("the target holds %q, want the committed v1", got)
	}
	if exists(aside) {
		t.Error("the provisional tree from the interrupted recovery is still there")
	}
}

func backupsBeside(t *testing.T, paths Paths) []string {
	t.Helper()

	entries, err := os.ReadDir(filepath.Dir(paths.ConfigDir))
	if err != nil {
		t.Fatal(err)
	}

	var found []string
	base := filepath.Base(paths.ConfigDir)
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), base+backupMark) {
			found = append(found, filepath.Join(filepath.Dir(paths.ConfigDir), entry.Name()))
		}
	}
	return found
}

// The ordering earns its keep here: recovery moves the uncommitted tree aside
// rather than deleting it, so a recovery that cannot put the committed
// generation back leaves the machine with a configuration rather than with
// nothing.
func TestARecoveryThatCannotFinishGivesTheTargetBack(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2-uncommitted", "v1")
	stopAt(t, faultDuringRepair)

	if _, err := Recover(paths, current); err == nil {
		t.Fatal("the interrupted repair reported success")
	}

	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Fatal("the target is empty: the uncommitted tree was not put back")
	}
	if got := held(t, paths.ConfigDir); got != "v2-uncommitted" {
		t.Errorf("the target holds %q, want the tree that was there", got)
	}

	// And the committed generation is still beside it, so a later attempt can
	// still do the right thing.
	if len(backupsBeside(t, paths)) != 1 {
		t.Error("the committed generation is no longer there to restore")
	}
}
