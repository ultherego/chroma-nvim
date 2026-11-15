package main

import (
	"os"
	"strings"
	"syscall"
	"testing"
	"time"
)

// Regression: only the interrupt key was heard. A terminal closed during a
// bootstrap sends SIGHUP, a supervisor sends SIGTERM, and either killed the
// process between two steps with nothing put back.
func TestATransactionHearsEverySignalThatMeansStop(t *testing.T) {
	for _, one := range stopping {
		ctx, stop := interruptible()

		if err := syscall.Kill(os.Getpid(), one.(syscall.Signal)); err != nil {
			t.Fatal(err)
		}

		select {
		case <-ctx.Done():
		case <-time.After(2 * time.Second):
			t.Errorf("%v did not cancel the transaction", one)
		}
		stop()
	}
}

// An uninstall is finished rather than stopped, and says so.
func TestAnUninstallIsFinishedRatherThanStoppedPartway(t *testing.T) {
	for _, one := range stopping {
		finished := false

		printed, _ := say(t, func(_, errOut *os.File) int {
			uninterrupted(errOut, func() {
				if err := syscall.Kill(os.Getpid(), one.(syscall.Signal)); err != nil {
					t.Fatal(err)
				}
				// Long enough for the signal to have been delivered, and for a
				// process that was going to die of it to have died.
				time.Sleep(100 * time.Millisecond)
				finished = true
			})
			return exitOK
		})

		if !finished {
			t.Errorf("%v stopped the work", one)
		}
		if !strings.Contains(printed, "finished instead") {
			t.Errorf("%v: nothing said that it was asked to stop:\n%s", one, printed)
		}
	}
}
