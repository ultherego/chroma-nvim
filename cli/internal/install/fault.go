package install

import (
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// Fault points: the boundaries between two steps that both succeeded.
//
// A real operating system cannot be aimed. Permissions, ENOSPC, EXDEV and
// symlinks all produced genuine answers when the campaign put them in the way,
// but none of them can be made to happen *after* a rename worked and *before*
// the next write started — and that gap is where a transaction either has a
// defined state or does not.
//
// Not a simulated error in a step: `afterVerify` means verify really ran and
// really succeeded, and then the process stopped. Deliberately not a filesystem
// interface either — "fail on the third Rename" changes meaning the moment a
// refactor splits one rename into two, while "after the generation was restored"
// does not.
type faultPoint string

const (
	// Shared by the operations that place or move a tree.
	faultAfterBackup  faultPoint = "after-backup"
	faultAfterPlace   faultPoint = "after-place"
	faultAfterRestore faultPoint = "after-restore"

	// After the editor has done its work and said it is happy.
	faultAfterBootstrap faultPoint = "after-bootstrap"
	faultAfterVerify    faultPoint = "after-verify"

	// Uninstall's two, and the reason this file exists. The first is before the
	// user's own configuration has been given back; the second is after.
	faultAfterCurrentMoved faultPoint = "after-current-moved"
	faultAfterUserRestore  faultPoint = "after-user-restore"

	// The window a signal can land in that no ordinary error can: the user's
	// configuration is back where it belongs and nothing has written that down
	// yet. A returned error here is unreachable in production — the two
	// statements are adjacent — but a process that stops existing between them
	// is not, and that is what this names.
	faultRestoredNotRecorded faultPoint = "restored-not-recorded"

	// Inside recovery itself, between moving the uncommitted tree aside and
	// putting the committed one back. Recovery has to survive being interrupted
	// too, and this is the only window in it where the target is empty.
	faultDuringRepair faultPoint = "during-repair"
)

// faults is nil everywhere except in a test that set it. There is no flag, no
// environment variable and no build tag: a way to make an installer fail on
// purpose is not something a released binary should carry.
var faults func(faultPoint) error

// hit reports whether a test has asked this boundary to stop.
func hit(point faultPoint) error {
	if faults == nil {
		return nil
	}
	return faults(point)
}

// writeRecord and writeSelection are the two durable writes this package makes.
// Package variables for the same reason the fault points exist: the window
// between "the rename committed" and "the caller was told" cannot be produced by
// any real failure, and it is the one where a transaction either keeps a commit
// or rolls back past it.
//
// This replaced an exported hook in internal/atomicfile. A test seam belongs in
// the package whose behaviour is under test, not in the API of the primitive it
// is built on.
var (
	writeRecord    = installstate.Write
	writeSelection = state.Write
)
