// Package lock keeps two mutating operations off one installation. `install`,
// `update`, `components`, `rollback` and `uninstall` all move directories and
// rewrite the record that says where they went; `doctor` is not here, because it
// reads.
//
// `flock` rather than a file holding a pid, for the case this whole campaign is
// about: a process that dies without running any cleanup. The kernel drops an
// flock when the descriptor closes, however the exit happened. A pid file would
// leave the next run guessing whether the pid it names is the same program.
package lock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

// Path is where the one lock lives. One for the whole CLI, not one per
// installation: what is protected is the selection both placements share, the
// discovery of which installation is managed, recovery and the generations. A
// per-installation lock measurably did not cover them — `install` took the
// isolated lock, the interactive flow chose the takeover, and the operation ran
// against an installation somebody else held.
//
// In the runtime directory rather than an installation's state, because a lock
// inside a directory `uninstall` removes stops working halfway through one: the
// name goes, the flock survives on an unreachable inode, and the next process
// locks a second file. Where there is no runtime directory the fallback is state
// rather than a shared temporary directory, since `/tmp/chroma.lock` is a name
// any account can take first.
func Path() (string, error) {
	if runtime := os.Getenv("XDG_RUNTIME_DIR"); runtime != "" {
		return filepath.Join(runtime, "chroma-nvim.lock"), nil
	}

	state := os.Getenv("XDG_STATE_HOME")
	if state == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("finding somewhere to coordinate operations: %w", err)
		}
		state = filepath.Join(home, ".local", "state")
	}
	// Not under any installation's directory, so no uninstall removes it.
	return filepath.Join(state, "chroma", "lock"), nil
}

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
