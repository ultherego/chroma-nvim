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

// An update killed after the place cannot be told from a complete installation
// with a stray directory beside it, and this records that limit rather than
// papering over it.
//
// From the filesystem alone the two arrangements are identical: a target that
// is there, every recorded path where the record says it is, and one
// unreferenced backup. H4 showed what happens when a rule is invented to tell
// them apart — the stray directory was moved over a perfectly good installation
// and the good one deleted. So this is refused, and the refusal says what to do.
//
// The cost is real and worth stating: a genuine update killed in that window is
// not repaired automatically any more. It is reported, and nothing is moved.
func TestAnInterruptedUpdateWithATargetInPlaceIsRefusedRatherThanGuessedAt(t *testing.T) {
	fixed(t)

	paths, current := interrupted(t, "v2-uncommitted", "v1")
	before := held(t, paths.ConfigDir)

	_, err := Recover(paths, current)
	if err == nil {
		t.Fatal("an ambiguous arrangement was reconciled anyway")
	}
	if !strings.Contains(err.Error(), "will not guess") {
		t.Errorf("the refusal does not say why it stopped: %v", err)
	}

	if got := held(t, paths.ConfigDir); got != before {
		t.Errorf("the target changed to %q despite the refusal", got)
	}
	if len(backupsBeside(t, paths)) != 1 {
		t.Error("the backup was moved or removed despite the refusal")
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

	// The tree the earlier attempt moved aside stays. After the process that
	// made it is gone, a `*.chroma-provisional-*` looks exactly like one
	// somebody created, and nothing here can tell them apart — so it is
	// reported rather than removed. The accepted cost of that rule.
	if !exists(aside) {
		t.Error("a directory nothing could prove was Chroma's was removed anyway")
	}
	if !strings.Contains(why, filepath.Base(aside)) {
		t.Errorf("the leftover was not mentioned: %q", why)
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

// H4: can the evidence for a handover be produced without one?
//
// `ReconcileHandover` concludes that the user's configuration was given back
// when the recorded backup is gone, the target is there, and the target does not
// look like a Chroma tree. The third of those is the weak one, and this tries to
// forge it: Chroma is still installed and running, somebody deletes the backup
// and one file out of the tree.
//
// The two statements are not the same. "This no longer looks like a complete
// Chroma tree" is not "this is exactly the configuration we were holding for
// you", and a false positive here ends in Chroma treating its own directory as
// somebody else's.
func TestAHandoverCannotBeForgedByDeletingAMarker(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)

	// Chroma is installed and untouched at the target. The backup goes, and so
	// does the one file the inference looks for.
	if err := os.RemoveAll(userBackup); err != nil {
		t.Fatal(err)
	}
	if err := os.Remove(filepath.Join(current.ConfigDir, "lua", "chroma", "bootstrap.lua")); err != nil {
		t.Fatal(err)
	}

	repaired, why, err := ReconcileHandover(current)

	if why != "" || err != nil || repaired.Handover == installstate.HandoverHandedBack {
		t.Errorf("a handover was inferred from a deleted marker, with Chroma still installed:\n  %s", why)
	}
}

// Pending says a transfer began; it does not say it finished. With the backup
// gone and Chroma still in the target, the two do not add up and nothing is
// concluded.
func TestAPendingHandoverWithChromaStillInPlaceIsRefused(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)
	current.Handover = installstate.HandoverPending
	if err := os.RemoveAll(userBackup); err != nil {
		t.Fatal(err)
	}

	repaired, why, err := ReconcileHandover(current)
	if err == nil {
		t.Error("a contradictory pending handover was reconciled anyway")
	}
	if why != "" || repaired.Handover == installstate.HandoverHandedBack {
		t.Errorf("the record was moved forward on a contradiction: why=%q handover=%q", why, repaired.Handover)
	}
}

// And with both gone there is nothing to reason from at all.
func TestAPendingHandoverWithNothingLeftIsRefused(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)
	current.Handover = installstate.HandoverPending
	for _, path := range []string{userBackup, current.ConfigDir} {
		if err := os.RemoveAll(path); err != nil {
			t.Fatal(err)
		}
	}

	if _, _, err := ReconcileHandover(current); err == nil {
		t.Error("a handover was concluded with neither directory present")
	}
}

// H4's last target. The committed topology is complete: the target holds the
// installed generation and the recorded previous is where the record says. A
// stray `*.chroma-backup-*` beside them explains nothing that is missing,
// because nothing is missing.
//
// An unreferenced backup is evidence of an interrupted transaction only when its
// presence closes a gap in the committed state. On its own it is a directory
// with a familiar name, and a familiar name is not proof of ownership.
func TestAStrayBackupBesideACompleteTopologyIsNotTreatedAsRecovery(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	mark(t, paths.ConfigDir, "installed")
	mark(t, current.Previous.Path, "previous")

	stray := paths.ConfigDir + backupMark + "20260810T999999Z"
	if err := os.MkdirAll(filepath.Join(stray, "lua", "chroma"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(stray, "lua", "chroma", "bootstrap.lua"), "return {}\n")
	write(t, filepath.Join(stray, "init.lua"), "-- who knows\n")
	mark(t, stray, "stray")

	before, err := os.ReadFile(paths.InstallState)
	if err != nil {
		t.Fatal(err)
	}

	if _, err := Recover(paths, current); err != nil {
		t.Logf("recovery refused, which is one acceptable answer: %v", err)
	}

	if got := held(t, paths.ConfigDir); got != "installed" {
		t.Errorf("the installed generation was replaced by %q", got)
	}
	if got := held(t, current.Previous.Path); got != "previous" {
		t.Errorf("the recorded previous generation became %q", got)
	}
	if got := held(t, stray); got != "stray" {
		t.Errorf("the stray directory was moved or replaced: %q", got)
	}

	after, err := os.ReadFile(paths.InstallState)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Error("the record changed although nothing was missing from the topology")
	}
}
