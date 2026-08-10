package lock

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestASecondHolderIsRefusedRatherThanQueued(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer first.Release()

	// flock is per open file description, so a second Acquire conflicts even
	// from the same process — which is what makes this testable without one.
	second, err := Acquire(path)
	if second != nil {
		second.Release()
	}
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy", err)
	}
}

func TestReleasingLetsTheNextOneIn(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}

	second, err := Acquire(path)
	if err != nil {
		t.Fatalf("the lock was not released: %v", err)
	}
	second.Release()
}

// The reason for flock rather than a pid file, made into a test: a process that
// is killed without running anything must not leave the installation locked.
func TestAKilledHolderDoesNotLeaveItLocked(t *testing.T) {
	if os.Getenv("CHROMA_LOCK_CHILD") == "1" {
		held, err := Acquire(os.Getenv("CHROMA_LOCK_PATH"))
		if err != nil {
			os.Exit(2)
		}
		_ = held
		// Say the lock is held, then wait to be killed.
		os.Stdout.WriteString("held\n")
		select {}
	}

	path := filepath.Join(t.TempDir(), "state", "lock")

	child := exec.Command(os.Args[0], "-test.run=TestAKilledHolderDoesNotLeaveItLocked")
	child.Env = append(os.Environ(), "CHROMA_LOCK_CHILD=1", "CHROMA_LOCK_PATH="+path)
	out, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}

	// Wait until it says it has the lock.
	buffer := make([]byte, len("held\n"))
	if _, err := out.Read(buffer); err != nil {
		t.Fatalf("the child never took the lock: %v", err)
	}

	if _, err := Acquire(path); !errors.Is(err, ErrBusy) {
		t.Errorf("err = %v, want ErrBusy while the child holds it", err)
	}

	// SIGKILL: no defer runs, no handler runs, nothing is cleaned up.
	if err := child.Process.Kill(); err != nil {
		t.Fatal(err)
	}
	_ = child.Wait()

	after, err := Acquire(path)
	if err != nil {
		t.Fatalf("the lock survived a killed holder, which is the failure flock exists to avoid: %v", err)
	}
	after.Release()
}

func TestReleaseIsSafeToCallTwice(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state", "lock")

	held, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := held.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}
	if err := held.Release(); err != nil {
		t.Errorf("a second Release complained: %v", err)
	}
}

// Why the lock does not live in a directory anything removes.
//
// Unlinking a held lock file ends the exclusion: the kernel keeps the first
// flock alive on an inode that no longer has a name, and the next Acquire
// creates a second inode and locks that instead. Two processes, two exclusive
// locks, one installation — which is what happened while the lock sat in the
// state directory `uninstall` removes.
//
// This asserts the hazard rather than the fix, because it is a property of the
// primitive and not something to be defended against in it. The defence is
// where Path() puts the file.
func TestUnlinkingAHeldLockFileEndsTheExclusion(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "state")
	path := filepath.Join(dir, "lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer first.Release()

	if _, err := Acquire(path); !errors.Is(err, ErrBusy) {
		t.Fatalf("err = %v, want ErrBusy while it is held", err)
	}

	if err := os.RemoveAll(dir); err != nil {
		t.Fatal(err)
	}

	second, err := Acquire(path)
	if err != nil {
		t.Fatalf("this is the hazard being documented and it did not reproduce: %v", err)
	}
	second.Release()
}

// So the one lock lives where no installation does.
func TestThePathIsNotInsideAnyInstallation(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")

	path, err := Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}
	if !strings.HasPrefix(path, "/run/user/1000/") {
		t.Errorf("path = %q, want it in the runtime directory", path)
	}

	// Without one, it falls back to state — but to Chroma's own, not to an
	// installation's, and not to a shared temporary directory whose name any
	// account could take first.
	t.Setenv("XDG_RUNTIME_DIR", "")
	t.Setenv("XDG_STATE_HOME", "/home/somebody/.local/state")

	path, err = Path()
	if err != nil {
		t.Fatalf("Path: %v", err)
	}
	if path != "/home/somebody/.local/state/chroma/lock" {
		t.Errorf("path = %q, want it beside the selection rather than in an installation", path)
	}
	for _, appname := range []string{"nvim", "chroma-nvim"} {
		if strings.Contains(path, "/state/"+appname+"/") {
			t.Errorf("path = %q, which uninstall removes", path)
		}
	}
	if strings.HasPrefix(path, "/tmp/") {
		t.Errorf("path = %q, which is a name any account can take first", path)
	}
}
