package install

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// A killed process is a different question from a failing one. SIGINT and
// SIGTERM leave a program able to answer; SIGKILL does not — no defer, no
// handler, no rollback, and the only thing the kernel does is drop the flock.
//
// So the question is not "does it undo itself", because it cannot. It is:
// **can the next run tell what happened and get out of it without destroying
// anything?** Either Chroma proves what the state is and repairs it, or it
// refuses and says what it found. What is not acceptable is believing the
// record over the filesystem when the two disagree.
//
// The child re-executes this test binary, arms one fault point to kill itself,
// and dies mid-transaction on a real temporary tree.
func killedAt(t *testing.T, scenario string, point faultPoint) Paths {
	t.Helper()

	root := t.TempDir()
	child := exec.Command(os.Args[0], "-test.run=TestCrashChild")
	child.Env = append(os.Environ(),
		"CHROMA_CRASH_SCENARIO="+scenario,
		"CHROMA_CRASH_AT="+string(point),
		"CHROMA_CRASH_ROOT="+root,
	)
	child.Stdout, child.Stderr = os.Stderr, os.Stderr

	err := child.Run()
	exit, ok := err.(*exec.ExitError)
	if !ok {
		t.Fatalf("the child did not die as expected: %v", err)
	}
	if status, fine := exit.Sys().(syscall.WaitStatus); !fine || status.Signal() != syscall.SIGKILL {
		t.Fatalf("the child exited %v, want death by SIGKILL", exit)
	}

	return pathsUnder(t, root)
}

// TestCrashChild is the far side of every crash test: it builds a real
// installation in a directory the parent chose, arms one boundary to kill the
// process, and runs a real operation into it. It does nothing when run
// ordinarily, which is what keeps it out of the suite.
func TestCrashChild(t *testing.T) {
	scenario := os.Getenv("CHROMA_CRASH_SCENARIO")
	if scenario == "" {
		t.Skip("this is the child half of the crash tests")
	}

	point := faultPoint(os.Getenv("CHROMA_CRASH_AT"))
	root := os.Getenv("CHROMA_CRASH_ROOT")
	fixed(t)

	// Armed only once the fixture is built. Setting it earlier kills the child
	// during its own setup — the setup installs, and an install passes through
	// the same boundaries the operation under test does. Measured: the record
	// was simply absent afterwards, because the process died before writing it.
	arm := func() {
		faults = func(at faultPoint) error {
			if at == point {
				// Nothing after this line runs: no defer, no rollback, no commit.
				syscall.Kill(os.Getpid(), syscall.SIGKILL)
			}
			return nil
		}
	}

	installer := &Installer{Runner: &failAt{}}

	switch scenario {
	case "uninstall":
		paths, current, _ := takenOverUnder(t, root)
		arm()
		_, _ = installer.Uninstall(paths, current)

	case "update":
		paths, current := installedUnder(t, root, []string{"terraform"})
		mark(t, paths.ConfigDir, "v1")
		current.Version = "v1.0.0"
		current.Source = installstate.Source{Type: installstate.FromRelease, Ref: "v1.0.0", SHA256: "a"}
		if _, err := installstate.Write(paths.InstallState, current); err != nil {
			t.Fatal(err)
		}
		source := preparedMarked(t, "v2")
		arm()
		_, _ = installer.Update(context.Background(), paths, source, shipped(t), []string{"terraform"}, current)

	case "rollback":
		paths, current := twoGenerationsUnder(t, root, nil)
		arm()
		_, _ = installer.Rollback(context.Background(), paths, shipped(t), nil, current)

	default:
		t.Fatalf("unknown scenario %q", scenario)
	}

	t.Fatal("the child survived a SIGKILL it asked for")
}

// mark writes a generation marker into README.md rather than into a file of its
// own, because a file of its own does not survive staging: the packager and the
// installer copy RuntimeEntries and nothing else, so a stray name at the root is
// dropped. That is the allowlist working, and the marker has to live inside it.
func mark(t *testing.T, dir, generation string) {
	t.Helper()

	// The directory keeps the modification time it had. A test that labels a
	// generation is standing in for a release having been installed there, not
	// for somebody adding a file to a directory Chroma is holding — and the
	// second of those is a thing the identity proof is meant to notice, so a
	// fixture must not do it by accident.
	//
	// Only a directory's own entries change its mtime, and this adds one, so
	// without the restore every marked directory would stop being provably the
	// one that was recorded.
	before, err := os.Lstat(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte(generation), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(dir, time.Time{}, before.ModTime()); err != nil {
		t.Fatal(err)
	}
}

// preparedMarked is a source tree carrying a generation marker, so that what
// ends up at the target can be told from what was there before.
func preparedMarked(t *testing.T, generation string) PreparedSource {
	t.Helper()

	source := prepared(t)
	mark(t, source.Root, generation)
	return source
}

// pathsUnder resolves the installation the child left behind.
func pathsUnder(t *testing.T, root string) Paths {
	t.Helper()

	xdg(t, root)
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	return paths
}

// The window H2B closed against ordinary errors, reopened by a signal: the
// user's configuration is back where it belongs and nothing has written that
// down. A record that still offers to restore it is a record that disagrees
// with the disk.
func TestUninstallKilledBetweenRestoreAndRecord(t *testing.T) {
	paths := killedAt(t, "uninstall", faultRestoredNotRecorded)

	// What the disk says.
	back, err := os.ReadFile(filepath.Join(paths.ConfigDir, "init.lua"))
	if err != nil {
		t.Fatalf("the configuration directory is unreadable after the kill: %v", err)
	}
	if !strings.Contains(string(back), "mine, not Chroma") {
		t.Fatalf("%s does not hold the user's configuration: %q", paths.ConfigDir, back)
	}

	// What the record says.
	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("the record is unreadable: %v found=%v", err, found)
	}
	if handoverOf(record, "configuration") != installstate.HandoverPending {
		t.Fatalf("handover = %q, want pending: the kill was inside the transfer", handoverOf(record, "configuration"))
	}
	if borrowedBackup(record, "configuration") == "" {
		t.Fatal("the record names nothing to restore, so this is not the window under test")
	}
	if exists(borrowedBackup(record, "configuration")) {
		t.Fatalf("%s still exists, so the restore had not happened", borrowedBackup(record, "configuration"))
	}

	// The two disagree, and the filesystem wins. A second run works out that the
	// handover already happened — the backup is gone, the directory is there and
	// it is not a Chroma tree — repairs the record and finishes the cleanup.
	repaired, why, err := ReconcileHandover(record)
	if err != nil {
		t.Fatalf("ReconcileHandover: %v", err)
	}
	if why == "" {
		t.Fatal("the disagreement was not noticed at all")
	}
	if handoverOf(repaired, "configuration") != installstate.HandoverHandedBack {
		t.Errorf("the repair did not conclude the handover: %+v", repaired)
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, record); err != nil {
		t.Fatalf("the second run could not finish: %v", err)
	}

	again, readErr := os.ReadFile(filepath.Join(paths.ConfigDir, "init.lua"))
	if readErr != nil {
		t.Fatalf("the second run took the user's configuration: %v", readErr)
	}
	if string(again) != string(back) {
		t.Errorf("the second run changed the user's configuration to %q", again)
	}

	// And Chroma is actually gone, rather than the run having refused politely.
	for _, path := range []string{paths.InstallState, paths.DataDir, paths.CacheDir} {
		if exists(path) {
			t.Errorf("%s survived the second run", path)
		}
	}
}

// The other reading of the same evidence, which must not be confused with it:
// the backup is gone because somebody deleted it, and Chroma is still installed.
// Nothing can be concluded, so nothing is repaired.
func TestADeletedBackupIsNotMistakenForAHandover(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)
	if err := os.RemoveAll(userBackup); err != nil {
		t.Fatal(err)
	}

	repaired, why, err := ReconcileHandover(current)
	if why != "" || err != nil {
		t.Errorf("a deleted backup was acted on: why=%q err=%v", why, err)
	}
	if handoverOf(repaired, "configuration") == installstate.HandoverHandedBack {
		t.Error("the record was marked as handed back with Chroma still installed")
	}
}

// The plan is printed before anybody agrees to it, so it has to be built from
// the reconciled record — without that, a run interrupted between the restore
// and the record offers to move a configuration it has already given back.
//
// Since borrowing became plural a borrowed path is never on the removal list at
// all, so what an unreconciled record produces is an offer to hand back a
// directory that has already gone home. That is what this asserts, and the old
// assertion is kept as the invariant it has become: neither plan names it.
func TestThePlanAfterAnInterruptedHandoverDoesNotOfferTheUsersConfiguration(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)

	// The state a kill in that window leaves: the intention recorded, the backup
	// consumed by the rename, the completion not written.
	current = pendingHandover(current)
	if err := os.RemoveAll(current.ConfigDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(userBackup, current.ConfigDir); err != nil {
		t.Fatal(err)
	}

	naive := PlanUninstall(Paths{}, current)
	if len(naive.GiveBack) != 1 {
		t.Fatalf("the unreconciled plan owes %d directories, so this proves nothing", len(naive.GiveBack))
	}
	for _, path := range naive.Remove {
		if path == current.ConfigDir {
			t.Errorf("a borrowed path was offered for removal: %s", path)
		}
	}

	repaired, why, err := ReconcileHandover(current)
	if err != nil {
		t.Fatalf("ReconcileHandover: %v", err)
	}
	if why == "" {
		t.Fatal("the interrupted handover was not recognised")
	}

	reconciled := PlanUninstall(Paths{}, repaired)
	if len(reconciled.GiveBack) != 0 {
		t.Errorf("the reconciled plan still offers to hand back %+v", reconciled.GiveBack)
	}
	for _, path := range reconciled.Remove {
		if path == current.ConfigDir {
			t.Errorf("the reconciled plan still offers to remove %s", current.ConfigDir)
		}
	}
}

// observeCrash reports what the record says and what the disk says, which is
// the only comparison that matters after a kill.
func observeCrash(t *testing.T, paths Paths) (installstate.State, string, []string) {
	t.Helper()

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("the record is unreadable after the kill: %v found=%v", err, found)
	}

	onDisk := "<no target>"
	if contents, err := os.ReadFile(filepath.Join(paths.ConfigDir, "README.md")); err == nil {
		onDisk = string(contents)
	} else if exists(paths.ConfigDir) {
		onDisk = "<target, unmarked>"
	}

	var beside []string
	entries, err := os.ReadDir(filepath.Dir(paths.ConfigDir))
	if err != nil {
		t.Fatal(err)
	}
	base := filepath.Base(paths.ConfigDir)
	for _, entry := range entries {
		if entry.Name() != base && strings.HasPrefix(entry.Name(), base) {
			generation := "?"
			if contents, err := os.ReadFile(filepath.Join(filepath.Dir(paths.ConfigDir), entry.Name(), "README.md")); err == nil {
				generation = string(contents)
			}
			beside = append(beside, entry.Name()+"="+generation)
		}
	}
	return record, onDisk, beside
}

// An update killed with the old generation moved aside and nothing put in its
// place. The record still describes the last committed state, which is the
// generation now sitting beside the target rather than in it.
func TestUpdateKilledWithTheTargetEmpty(t *testing.T) {
	paths := killedAt(t, "update", faultAfterBackup)
	record, onDisk, beside := observeCrash(t, paths)

	t.Logf("record says %q; target holds %q; beside: %v", record.Version, onDisk, beside)

	if onDisk != "<no target>" {
		t.Fatalf("the target is %q, so the kill did not land where this test needs it", onDisk)
	}
	if record.Version != "v1.0.0" {
		t.Errorf("the record says %q, want the last committed v1.0.0", record.Version)
	}

	// The question: can the next run tell that the installation it describes is
	// beside the target rather than missing?
	if len(beside) == 0 {
		t.Fatal("the generation the record describes is nowhere at all")
	}
}

// An update killed with the new generation in place and the record still
// naming the old one. This is the split-brain a rollback would have prevented
// and a kill does not give it the chance to.
func TestUpdateKilledWithTheNewGenerationInPlace(t *testing.T) {
	paths := killedAt(t, "update", faultAfterPlace)
	record, onDisk, beside := observeCrash(t, paths)

	t.Logf("record says %q; target holds %q; beside: %v", record.Version, onDisk, beside)

	if onDisk != "v2" {
		t.Fatalf("the target holds %q, so the kill did not land where this test needs it", onDisk)
	}
	if record.Version != "v1.0.0" {
		t.Fatalf("the record says %q, so this is not the disagreement under test", record.Version)
	}

	// What the next run makes of it. The record is the only thing `update`,
	// `rollback` and `uninstall` consult, so if nothing notices the
	// disagreement they all act on a map that is wrong.
	orphans := 0
	for _, name := range beside {
		if strings.Contains(name, "chroma-backup") {
			orphans++
		}
	}
	if orphans == 0 {
		t.Fatal("no backup directory beside the target, so there is no evidence to work from")
	}
	if record.Previous != nil {
		t.Fatalf("the record already names a previous generation: %+v", record.Previous)
	}

	// This is the finding: a `chroma-backup-*` directory the record does not
	// reference cannot exist in any committed state — an install records it as
	// user_backup, an update and a rollback record it as previous.path. Its
	// presence is durable proof that a transaction was interrupted between its
	// backup step and its record write. Nothing acts on that proof yet.
	t.Logf("orphaned backup: %v, record.previous=nil, target=%q, record=%q — nothing reconciles this",
		beside, onDisk, record.Version)
}

// A rollback killed with both directories moved and nothing written down.
func TestRollbackKilledAfterTheSwap(t *testing.T) {
	paths := killedAt(t, "rollback", faultAfterRestore)
	record, onDisk, beside := observeCrash(t, paths)

	t.Logf("record says current=%q previous=%v; target holds %q; beside: %v",
		record.Version, record.Previous != nil, onDisk, beside)
}
