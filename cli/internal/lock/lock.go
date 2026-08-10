// Package lock keeps two mutating operations off one installation.
//
// `install`, `update`, `components`, `rollback` and `uninstall` all move
// directories and rewrite the record that says where they went. Two of them at
// once is not a race that ends in a slow answer; it is one process renaming a
// tree the other is about to write a state file about. `doctor` is not here on
// purpose: it reads.
//
// The lock is `flock` rather than a file holding a pid. The difference is the
// case this whole campaign is about — a process that dies without running any
// cleanup. The kernel drops an flock when the file descriptor closes, which it
// does on exit however the exit happened, including SIGKILL. A pid file would
// still be there, and the next run would have to decide whether the pid it
// names is the same program or a number the system has since reused. That
// decision is a guess, and it is a guess made at the exact moment somebody is
// already having a bad day.
package lock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// ErrBusy is returned when another process holds the lock.
var ErrBusy = errors.New("another Chroma operation is already in progress")

// Lock is a held lock. Release it, or let the process end.
type Lock struct {
	file *os.File
}

// Acquire takes the exclusive lock for one installation, without waiting.
//
// Without waiting on purpose. A CLI that blocks looks identical to a CLI that
// has hung, and the useful thing to tell somebody is that another operation is
// running — not to leave them watching a cursor while a thirty-minute
// bootstrap finishes somewhere else.
func Acquire(path string) (*Lock, error) {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return nil, fmt.Errorf("creating %s: %w", filepath.Dir(path), err)
	}

	// Not O_EXCL: the file is expected to survive between operations. What is
	// exclusive is the flock on it, not its existence.
	file, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return nil, fmt.Errorf("opening %s: %w", path, err)
	}

	if err := syscall.Flock(int(file.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		file.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) {
			return nil, ErrBusy
		}
		return nil, fmt.Errorf("locking %s: %w", path, err)
	}

	return &Lock{file: file}, nil
}

// Release drops the lock.
//
// The file stays. Removing it would open a window in which another process has
// opened it, the first unlinks it, a third creates a new one, and two of them
// hold locks on two different inodes with the same name — which is the classic
// way a lock file stops being a lock.
func (l *Lock) Release() error {
	if l == nil || l.file == nil {
		return nil
	}

	err := syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	closeErr := l.file.Close()
	l.file = nil

	return errors.Join(err, closeErr)
}
