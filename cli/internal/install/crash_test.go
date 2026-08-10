package install

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// A killed process is a different question from a failing one.
//
// SIGINT and SIGTERM leave a program able to answer: defers run, the
// transaction rolls back, the guarantees are the ones the fault points already
// hold. SIGKILL does not. Nothing runs — no defer, no handler, no rollback —
// and the only thing the kernel does on the way out is drop the flock.
//
// So the question here is not "does it undo itself", because it cannot. It is:
// **can the next run tell what happened and get out of it without destroying
// anything?** Two answers are acceptable. Either Chroma can prove what the
// state is and repair it, or it cannot and refuses, touching nothing and saying
// precisely what it found. What is not acceptable is believing the record over
// the filesystem when the two disagree.
//
// The child re-executes this test binary, arms one fault point to kill itself,
// and dies mid-transaction on a real temporary tree. The parent then looks.
func killedAt(t *testing.T, point faultPoint, prepare func(t *testing.T) (Paths, installstate.State, string)) (Paths, string) {
	t.Helper()

	if where := os.Getenv("CHROMA_CRASH_AT"); where != "" {
		return Paths{}, ""
	}

	root := t.TempDir()
	child := exec.Command(os.Args[0], "-test.run=TestUninstallKilledBetweenRestoreAndRecord")
	child.Env = append(os.Environ(),
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

	return pathsUnder(t, root), root
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
	if where := os.Getenv("CHROMA_CRASH_AT"); where != "" {
		runChild(t, faultPoint(where), os.Getenv("CHROMA_CRASH_ROOT"))
		return
	}

	paths, _ := killedAt(t, faultRestoredNotRecorded, nil)

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
	if record.HandedBack {
		t.Fatal("the record says the handover completed, but the kill was before it was written")
	}
	if record.UserBackup == "" {
		t.Fatal("the record names nothing to restore, so this is not the window under test")
	}
	if exists(record.UserBackup) {
		t.Fatalf("%s still exists, so the restore had not happened", record.UserBackup)
	}

	// The two disagree, and the filesystem wins. A second run works out that the
	// handover already happened — the backup is gone, the directory is there and
	// it is not a Chroma tree — repairs the record and finishes the cleanup.
	repaired, why := ReconcileHandover(record)
	if why == "" {
		t.Fatal("the disagreement was not noticed at all")
	}
	if !repaired.HandedBack || repaired.UserBackup != "" {
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

	repaired, why := ReconcileHandover(current)
	if why != "" {
		t.Errorf("a deleted backup was read as a completed handover: %s", why)
	}
	if repaired.HandedBack {
		t.Error("the record was marked as handed back with Chroma still installed")
	}
}

// The plan is printed before anybody agrees to it, so it has to be built from
// the reconciled record. Without that, a run interrupted between the restore
// and the record offers to remove the configuration it has already given back.
func TestThePlanAfterAnInterruptedHandoverDoesNotOfferTheUsersConfiguration(t *testing.T) {
	fixed(t)

	_, current, userBackup := takenOver(t)

	// The state a kill in that window leaves: the backup consumed by the
	// rename, the record still offering it.
	if err := os.RemoveAll(current.ConfigDir); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(userBackup, current.ConfigDir); err != nil {
		t.Fatal(err)
	}

	naive := PlanUninstall(Paths{}, current)
	offered := false
	for _, path := range naive.Remove {
		if path == current.ConfigDir {
			offered = true
		}
	}
	if !offered {
		t.Fatal("the unreconciled plan does not offer the directory, so this proves nothing")
	}

	repaired, why := ReconcileHandover(current)
	if why == "" {
		t.Fatal("the interrupted handover was not recognised")
	}
	for _, path := range PlanUninstall(Paths{}, repaired).Remove {
		if path == current.ConfigDir {
			t.Errorf("the reconciled plan still offers to remove %s", current.ConfigDir)
		}
	}
}

// runChild is the far side: a real uninstall on a real tree, killed at a point.
func runChild(t *testing.T, point faultPoint, root string) {
	fixed(t)
	paths, current, _ := takenOverUnder(t, root)

	faults = func(at faultPoint) error {
		if at == point {
			// No defer runs after this, which is the condition being created.
			syscall.Kill(os.Getpid(), syscall.SIGKILL)
		}
		return nil
	}

	installer := &Installer{}
	_, _ = installer.Uninstall(paths, current)
	t.Fatal("the child survived a SIGKILL it asked for")
}
