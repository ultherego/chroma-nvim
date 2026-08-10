package install

import (
	"errors"
	"fmt"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// Transaction remembers what an installation has actually done, so that it can
// be undone.
//
// Deliberately an object rather than a pile of deferred closures. Rollback is
// the path that runs when something has already gone wrong, which is the worst
// possible time to be working out what state the machine is in from control
// flow. Everything here is a fact that was recorded *after* it happened: the
// transaction never claims to have done something it only attempted.
//
// It grows with the installer. Today it owns the selection; placement, backup
// and staging arrive with the stage that introduces them.
type Transaction struct {
	// SelectionPath is the document this transaction may replace.
	SelectionPath string

	// PreviousSelection is the file as it was found, byte for byte, and
	// HadSelection says whether there was one at all. The distinction is the
	// same one the selection document itself rests on: no file and an empty
	// selection are different, and putting back the wrong one of the two would
	// change what the editor runs.
	PreviousSelection []byte
	HadSelection      bool

	// StageDir is the tree being assembled beside the target, and is emptied
	// when it becomes the target.
	StageDir string

	// Target is where the configuration was placed, Backup is where whatever
	// was there before was renamed to, and the two booleans are the only thing
	// rollback trusts: a path that is set but never happened would send it
	// moving directories that are not there.
	Target        string
	Backup        string
	Placed        bool
	BackupCreated bool

	// BackupIdentity is what the directory at Backup was when it was moved, so
	// that whatever records it as a generation records what it is and not only
	// where it went.
	BackupIdentity Identity

	// Held are Chroma's own directories moved out of the way so that borrowed
	// ones can go back where they belong. Moved rather than deleted: until the
	// directory that replaces one has actually arrived, the held copy is the
	// only thing at that path, and deleting first would make a failed restore
	// leave nothing at all.
	Held []heldAside

	// Borrowed are the directories that were not Chroma's, moved aside so that
	// Chroma could take their place. Separate from Backup and never mixed with
	// it: a backup is Chroma's own tree kept as a generation and may be
	// removed, and these are somebody else's work and may only be given back.
	Borrowed []installstate.Borrowed

	// RestoredFrom is where a generation was moved *from* when it was put back
	// into place, and Restored says it happened.
	//
	// Kept apart from Placed on purpose, and the difference is destructive: a
	// placed tree is one this transaction assembled, so undoing it means
	// deleting it. A restored generation is one that already existed and was
	// only moved, so undoing it means moving it back. Deleting it would destroy
	// the very thing a rollback exists to preserve.
	RestoredFrom string
	Restored     bool

	selectionWritten bool
	committed        bool
}

// heldAside is one Chroma directory moved out of the way, and where it went.
type heldAside struct {
	Original string
	Aside    string
}

// HoldAside moves a Chroma directory to a sibling of itself, so that whatever
// belongs at its path can be put back.
//
// Reports the path it was moved to, or an empty string when there was nothing
// there — which is not a failure: an installation whose cache was never written
// has no cache to hold.
func (tx *Transaction) HoldAside(original string) (string, error) {
	if _, err := os.Lstat(original); errors.Is(err, os.ErrNotExist) {
		return "", nil
	} else if err != nil {
		return "", fmt.Errorf("looking at %s: %w", original, err)
	}

	aside, err := asideFrom(original)
	if err != nil {
		return "", err
	}
	if err := os.Rename(original, aside); err != nil {
		return "", fmt.Errorf("moving %s aside to %s: %w", original, aside, err)
	}

	tx.Held = append(tx.Held, heldAside{Original: original, Aside: aside})
	return aside, nil
}

// giveBackHeld puts Chroma's own directories back where they were, in reverse.
func (tx *Transaction) giveBackHeld() error {
	var problems []error
	kept := tx.Held[:0]

	for index := len(tx.Held) - 1; index >= 0; index-- {
		one := tx.Held[index]
		if _, err := os.Lstat(one.Original); err == nil {
			// Something is there, so this cannot go back without destroying it.
			// Reported rather than forced: the aside is still on disk under a
			// name that says what it is.
			problems = append(problems, fmt.Errorf("not putting %s back as %s: something is already there", one.Aside, one.Original))
			kept = append(kept, one)
			continue
		}
		if err := os.Rename(one.Aside, one.Original); err != nil {
			problems = append(problems, fmt.Errorf("putting %s back as %s: %w", one.Aside, one.Original, err))
			kept = append(kept, one)
		}
	}

	for left, right := 0, len(kept)-1; left < right; left, right = left+1, right-1 {
		kept[left], kept[right] = kept[right], kept[left]
	}
	tx.Held = kept
	return errors.Join(problems...)
}

// NewTransaction starts a transaction against one installation's paths.
func NewTransaction(paths Paths) *Transaction {
	return &Transaction{SelectionPath: paths.SelectionFile}
}

// WriteSelection records what was there and then writes what was chosen.
//
// In that order, and the capture is not optional: a write that succeeded with
// nothing captured is a selection that cannot be put back. `set` is the
// contract the selection is checked against, so a selection this writes is one
// the editor will read rather than drop into safe mode over.
func (tx *Transaction) WriteSelection(selected []string, set component.Set) error {
	previous, err := os.ReadFile(tx.SelectionPath)
	switch {
	case err == nil:
		tx.PreviousSelection = previous
		tx.HadSelection = true
	case errors.Is(err, os.ErrNotExist):
		tx.HadSelection = false
	default:
		return fmt.Errorf("reading the selection at %s before replacing it: %w", tx.SelectionPath, err)
	}

	// Marked from what actually happened, not from whether the call succeeded.
	// A write that failed after its rename has replaced the document, and a
	// transaction that believed otherwise would roll back without putting the
	// old selection back — leaving the change it just reported as failed in
	// force.
	result, err := writeSelection(tx.SelectionPath, state.State{Selected: selected}, set)
	tx.selectionWritten = result.Replaced
	if err != nil {
		return err
	}

	return nil
}

// Commit says the installation succeeded, and Rollback stops undoing anything.
func (tx *Transaction) Commit() {
	tx.committed = true
}

// Rollback puts back what was there. It is safe to call more than once, and
// safe to call when nothing has happened yet.
//
// It reports its own failures rather than swallowing them. A rollback that
// quietly did not work is the one thing worse than the failure that caused it,
// because the user is then told the previous state was restored when it was
// not.
// It undoes things in the reverse of the order they happened, and each step
// clears its own fact only once it has worked — so a rollback that failed
// partway can be run again and will resume where it stopped, rather than
// repeating what already succeeded.
func (tx *Transaction) Rollback() error {
	if tx.committed {
		return nil
	}

	var problems []error

	// A restored generation goes back where it came from, before anything else
	// wants the target. Moved, never removed: it is a directory this
	// transaction did not create.
	if tx.Restored {
		if err := os.Rename(tx.Target, tx.RestoredFrom); err != nil {
			problems = append(problems, fmt.Errorf("putting %s back as %s: %w", tx.Target, tx.RestoredFrom, err))
		} else {
			tx.Restored = false
		}
	}

	// The configuration first, because the selection is meaningless beside a
	// tree that is not there.
	if tx.Placed {
		if err := os.RemoveAll(tx.Target); err != nil {
			problems = append(problems, fmt.Errorf("removing the configuration placed at %s: %w", tx.Target, err))
		} else {
			tx.Placed = false
		}
	}

	// Only once the target is out of the way, and only if this transaction is
	// the one that moved it.
	if tx.BackupCreated && !tx.Placed && !tx.Restored {
		if err := os.Rename(tx.Backup, tx.Target); err != nil {
			problems = append(problems, fmt.Errorf("putting %s back as %s: %w", tx.Backup, tx.Target, err))
		} else {
			tx.BackupCreated = false
		}
	}

	// Chroma's own directories, put back before the borrowed ones so that a
	// half-done handover leaves the installation it was removing intact.
	if len(tx.Held) > 0 {
		if err := tx.giveBackHeld(); err != nil {
			problems = append(problems, err)
		}
	}

	// Last of the directory moves, because everything above wants the paths
	// these would be put back at to be free.
	if len(tx.Borrowed) > 0 && !tx.Placed && !tx.Restored && !tx.BackupCreated {
		if err := tx.giveBackBorrowed(); err != nil {
			problems = append(problems, err)
		}
	}

	if tx.StageDir != "" {
		if err := os.RemoveAll(tx.StageDir); err != nil {
			problems = append(problems, fmt.Errorf("removing the staging directory %s: %w", tx.StageDir, err))
		} else {
			tx.StageDir = ""
		}
	}

	if tx.selectionWritten {
		var err error
		if tx.HadSelection {
			_, err = state.Restore(tx.SelectionPath, tx.PreviousSelection)
		} else {
			// There was no file, so leaving one behind would be this installer
			// inventing a selection the user never made.
			if removeErr := os.Remove(tx.SelectionPath); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
				err = removeErr
			}
		}
		if err != nil {
			problems = append(problems, fmt.Errorf("restoring the selection at %s: %w", tx.SelectionPath, err))
		} else {
			tx.selectionWritten = false
		}
	}

	return errors.Join(problems...)
}

// Cleanup removes what a *successful* installation leaves behind — the staging
// directory, if placement did not consume it. It is not a rollback and must not
// be confused with one: it never touches the target, the backup or the
// selection.
func (tx *Transaction) Cleanup() error {
	if tx.StageDir == "" {
		return nil
	}
	if err := os.RemoveAll(tx.StageDir); err != nil {
		return fmt.Errorf("removing the staging directory %s: %w", tx.StageDir, err)
	}
	tx.StageDir = ""
	return nil
}
