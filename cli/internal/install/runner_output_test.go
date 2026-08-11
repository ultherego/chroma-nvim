package install

import (
	"context"
	"strings"
	"testing"
)

// **Point 14b.** A child that succeeds, and whose output could not be read.
//
// The scanner has a one-megabyte limit. A longer line makes Scan return false
// with ErrTooLong, which is indistinguishable from end-of-output unless Err() is
// asked — and it was not. The child then exits 0 and the runner reports success,
// having lost the output it was reading and, with it, any idea of what the
// editor actually did.
func TestOutputThatCouldNotBeReadIsNotSuccess(t *testing.T) {
	runner := ExecRunner{}

	// One line of two megabytes, then a clean exit.
	err := runner.Run(context.Background(), Command{
		Name: "sh",
		Args: []string{"-c", "head -c 2000000 /dev/zero | tr '\\0' 'x'; echo; exit 0"},
	}, Discard{})

	if err == nil {
		t.Fatal("a run whose output could not be read reported success")
	}
	if !strings.Contains(err.Error(), "output") {
		t.Errorf("the error does not say what went wrong: %v", err)
	}
}

// The ordinary case still succeeds, so the fix is not "always fail".
func TestOutputThatFitsIsStillSuccess(t *testing.T) {
	runner := ExecRunner{}
	if err := runner.Run(context.Background(), Command{
		Name: "sh", Args: []string{"-c", "echo hello; exit 0"},
	}, Discard{}); err != nil {
		t.Errorf("an ordinary run failed: %v", err)
	}
}

// A child that fails still reports its own failure, with the tail of what it
// said, rather than being replaced by a reading problem.
func TestAFailingChildStillReportsItsOwnFailure(t *testing.T) {
	runner := ExecRunner{}
	err := runner.Run(context.Background(), Command{
		Name: "sh", Args: []string{"-c", "echo the reason; exit 3"},
	}, Discard{})

	if err == nil {
		t.Fatal("a child that exited 3 reported success")
	}
	if !strings.Contains(err.Error(), "the reason") {
		t.Errorf("the error lost what the child said: %v", err)
	}
}
