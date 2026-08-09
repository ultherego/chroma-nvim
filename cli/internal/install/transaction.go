package install

import (
	"errors"
	"fmt"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
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

	selectionWritten bool
	committed        bool
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

	if err := state.Write(tx.SelectionPath, state.State{Selected: selected}, set); err != nil {
		return err
	}

	tx.selectionWritten = true
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
	if tx.BackupCreated && !tx.Placed {
		if err := os.Rename(tx.Backup, tx.Target); err != nil {
			problems = append(problems, fmt.Errorf("putting %s back as %s: %w", tx.Backup, tx.Target, err))
		} else {
			tx.BackupCreated = false
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
			err = state.Restore(tx.SelectionPath, tx.PreviousSelection)
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
