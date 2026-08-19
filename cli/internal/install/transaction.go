package install

import (
	"errors"
	"fmt"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
	"github.com/ultherego/chroma-nvim/cli/internal/theme"
)

// Transaction remembers what an installation has actually done, so it can be
// undone. An object rather than a pile of deferred closures: rollback runs when
// something has already gone wrong, which is the worst time to be working out
// the state of the machine from control flow. Everything here is recorded
// *after* it happened.
type Transaction struct {
	// SelectionPath is the document this transaction may replace.
	SelectionPath string

	// PreviousSelection is the file as it was found, byte for byte, and
	// HadSelection says whether there was one. No file and an empty selection are
	// different, and putting back the wrong one changes what the editor runs.
	PreviousSelection []byte
	HadSelection      bool

	// ThemePath is the other document this transaction may replace, and the
	// three fields below are the selection's three, for the same reasons. Kept
	// apart rather than folded together: they are written at different moments
	// by different callers — an update never touches the theme — and a rollback
	// that put back a document this run never wrote would undo somebody else's
	// change.
	ThemePath     string
	PreviousTheme []byte
	HadTheme      bool

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

	// Held are Chroma's own directories moved out of the way so borrowed ones can
	// go back. Moved rather than deleted: the held copy is the only thing at that
	// path until the replacement arrives.
	Held []heldAside

	// Borrowed are the directories that were not Chroma's, moved aside so that
	// Chroma could take their place. Separate from Backup and never mixed with
	// it: a backup is Chroma's own tree kept as a generation and may be
	// removed, and these are somebody else's work and may only be given back.
	Borrowed []installstate.Borrowed

	// RestoredFrom is where a generation was moved *from* when it was put back,
	// and Restored says it happened. Kept apart from Placed because the
	// difference is destructive: undoing a placed tree means deleting it, and
	// undoing a restored generation means moving it back.
	RestoredFrom string
	Restored     bool

	selectionWritten bool
	themeWritten     bool
	committed        bool
}

// heldAside is one Chroma directory moved out of the way, and where it went.
type heldAside struct {
	Original string
	Aside    string
}

// HoldAside moves a Chroma directory to a sibling of itself, so whatever belongs
// at its path can be put back. Reports an empty string when there was nothing
// there, which is not a failure.
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
	return &Transaction{SelectionPath: paths.SelectionFile, ThemePath: paths.ThemeFile}
}

// WriteSelection records what was there and then writes what was chosen, in that
// order: a write that succeeded with nothing captured is a selection that cannot
// be put back. `set` is the contract it is checked against, so what this writes
// is what the editor will read rather than drop into safe mode over.
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

	// Marked from what actually happened, not from whether the call succeeded: a
	// write that failed after its rename has replaced the document, and rolling
	// back without putting the old selection back would leave the change in force.
	result, err := writeSelection(tx.SelectionPath, state.State{Selected: selected}, set)
	tx.selectionWritten = result.Replaced
	if err != nil {
		return err
	}

	return nil
}

// WriteTheme records what was there and then writes what was chosen, in that
// order and for the reason WriteSelection does it that way: a write that
// succeeded with nothing captured is a document that cannot be put back.
//
// An empty id writes nothing at all and is not a failure. That is what
// installing a release from before the colourscheme was a choice comes to, and
// what an update does every time — neither has an answer to record, and writing
// a default over somebody's own choice would be inventing one.
func (tx *Transaction) WriteTheme(id string, catalogue theme.Catalogue) error {
	if id == "" {
		return nil
	}

	previous, err := os.ReadFile(tx.ThemePath)
	switch {
	case err == nil:
		tx.PreviousTheme = previous
		tx.HadTheme = true
	case errors.Is(err, os.ErrNotExist):
		tx.HadTheme = false
	default:
		return fmt.Errorf("reading the theme at %s before replacing it: %w", tx.ThemePath, err)
	}

	// Marked from what actually happened rather than from whether the call
	// succeeded, for the reason given above WriteSelection's own write.
	result, err := theme.Write(tx.ThemePath, id, catalogue)
	tx.themeWritten = result.Replaced
	if err != nil {
		return err
	}

	return nil
}

// Commit says the installation succeeded, and Rollback stops undoing anything.
func (tx *Transaction) Commit() {
	tx.committed = true
}

// Rollback puts back what was there. Safe to call more than once, and when
// nothing has happened yet. It reports its own failures rather than swallowing
// them: a rollback that quietly did not work tells the user the previous state
// was restored when it was not. Steps are undone in reverse, and each clears its
// own fact only once it has worked, so a rollback that failed partway resumes.
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

	if tx.themeWritten {
		var err error
		if tx.HadTheme {
			_, err = theme.Restore(tx.ThemePath, tx.PreviousTheme)
		} else {
			// There was no file, so leaving one behind would be this installer
			// recording a choice nobody got as far as making.
			if removeErr := os.Remove(tx.ThemePath); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
				err = removeErr
			}
		}
		if err != nil {
			problems = append(problems, fmt.Errorf("restoring the theme at %s: %w", tx.ThemePath, err))
		} else {
			tx.themeWritten = false
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
