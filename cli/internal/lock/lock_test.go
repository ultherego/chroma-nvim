package lock

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
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
