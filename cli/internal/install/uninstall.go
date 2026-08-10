package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// Removal is what an uninstall did.
type Removal struct {
	// Removed are the paths that are gone, in the order they went.
	Removed []string

	// Restored is the configuration given back to whoever had it before
	// Chroma, and is empty when Chroma was installed beside one rather than
	// over it.
	Restored string

	// Problems are the removals that did not work. An uninstall reports them
	// rather than stopping: a directory that could not be deleted is worth
	// naming, and refusing to remove the rest because of it would leave more
	// behind than carrying on does.
	Problems []error
}

// RemovalPlan is everything an uninstall would touch, worked out before it touches
// anything.
type RemovalPlan struct {
	// Remove are Chroma's own paths, which it made and may take away.
	Remove []string

	// Restore is the pre-Chroma configuration to give back, if there is one.
	Restore string

	// RestoreTo is where it goes.
	RestoreTo string
}

// undo puts a half-done uninstall back, and reports both problems if the
// putting back is what failed.
func undo(tx *Transaction, cause error) error {
	if problem := tx.Rollback(); problem != nil {
		return errors.Join(cause, problem)
	}
	return cause
}

// ReconcileHandover repairs a record left behind by a process that stopped
// existing between giving the user's configuration back and writing that down.
//
// A signal can land in that window; an error cannot, because the two statements
// are adjacent. What is left is a record saying "there is a configuration to
// restore" and a filesystem saying the opposite, and the rule is that the
// filesystem wins — a record is a description, and a description that disagrees
// with the thing it describes is wrong about it.
//
// The inference is allowed only where the record says a handover had begun.
// That is the whole difference from the version H4 forged: with Chroma still
// installed, deleting the backup and one file out of the tree was enough to make
// the old rule conclude the configuration had been given back — because it asked
// what the directory looked like. "This no longer looks like a complete Chroma
// tree" is not "this is exactly what we were holding for you".
//
// `pending` is written before the first move, so its presence is Chroma's own
// record of having entered the transfer. Only then is the topology worth
// reading, and only these three together mean the rename ran:
//
//   - the recorded backup is gone, and
//   - the configuration directory is there, and
//   - it does not hold a Chroma tree.
//
// Anything else with `pending` set is a contradiction — the backup gone and the
// target gone too, or the target still holding Chroma — and produces a refusal
// rather than a story.
//
// Returns the record to act on, a sentence for whoever is watching, and an
// error when nothing can be concluded safely.
func ReconcileHandover(current installstate.State) (installstate.State, string, error) {
	if current.Handover != installstate.HandoverPending {
		// Not in a transfer, so the state of the backup proves nothing about
		// ownership. A missing one is somebody else's doing and is refused
		// later, by name.
		return current, "", nil
	}

	if _, err := os.Lstat(current.UserBackup); err == nil {
		// Still there: the rename had not run, so the transfer simply resumes.
		return current, "", nil
	}

	if _, err := os.Stat(current.ConfigDir); err != nil {
		return current, "", fmt.Errorf(
			"a handover of %s was interrupted: it is no longer there and %s is empty, so this cannot tell where the configuration went",
			current.UserBackup, current.ConfigDir)
	}
	if isChromaTree(current.ConfigDir) {
		return current, "", fmt.Errorf(
			"a handover of %s was interrupted: it is no longer there and %s still holds a Chroma installation, so the two do not add up",
			current.UserBackup, current.ConfigDir)
	}

	repaired := current
	repaired.UserBackup = ""
	repaired.Handover = installstate.HandoverHandedBack

	return repaired, fmt.Sprintf(
		"An interrupted handover was found: %s is gone and %s no longer holds a Chroma installation, so the configuration you had before Chroma has already been given back.",
		current.UserBackup, current.ConfigDir), nil
}

// isChromaTree reports whether a directory holds a Chroma configuration.
//
// The same file LocalSource insists on before it will install anything, for the
// same reason: without it there is nothing here the installer could bootstrap,
// so whatever it is, it is not this.
func isChromaTree(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "lua", "chroma", "bootstrap.lua"))
	return err == nil
}

// RefuseSymlinkedConfiguration reports why a symlinked configuration cannot be
// uninstalled.
//
// Renaming a symlink moves the link, not what it points at, and removing it
// removes the link. An uninstall that did that would report a complete removal
// while the entire configuration sat where it always was — measured, not
// imagined: it deleted the link, left nine entries behind and said "6 paths
// removed".
//
// Following it instead is worse. What is on the other end was not made by
// Chroma; the README's own second installation route is to clone the repository
// somewhere and link to it, so the thing at the end of the link is quite likely
// a checkout with somebody's work in it. Neither lying nor deleting is
// acceptable, which leaves saying so.
//
// Exported because the refusal has to happen before the plan is printed — a
// destructive list nobody is going to act on reads as a threat — and the check
// still runs inside Uninstall, so no caller can skip it.
func RefuseSymlinkedConfiguration(configDir string) error {
	info, err := os.Lstat(configDir)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return nil
	}

	destination, readErr := os.Readlink(configDir)
	if readErr != nil {
		destination = "somewhere this cannot read"
	}
	return fmt.Errorf(
		"%s is a symbolic link to %s.\nChroma will not remove what is on the other end of it, and removing only the link would leave the configuration in place while reporting that it had gone.\nRemove the link yourself, and delete %s if you want it gone",
		configDir, destination, destination)
}

// PlanUninstall works out what an uninstall would do.
//
// The single rule, and everything here follows from it: **what Chroma made for
// its own operation it may remove; what Chroma only moved aside, because it
// belonged to somebody already, it gives back.** A generation is the first
// kind. The configuration that was in Neovim's directory before `--default`
// took it over is the second, and is never on the removal list.
func PlanUninstall(paths Paths, current installstate.State) RemovalPlan {
	plan := RemovalPlan{RestoreTo: current.ConfigDir}

	// The order is the order they go in: the configuration first, then what it
	// left beside itself, and the record of all of it last.
	//
	// Unless it has already been handed back, in which case the directory holds
	// somebody else's configuration and is not on any list of Chroma's.
	if current.Handover != installstate.HandoverHandedBack {
		plan.Remove = append(plan.Remove, current.ConfigDir)
	}

	if current.Previous != nil && current.Previous.Path != "" && current.Previous.Path != current.UserBackup {
		plan.Remove = append(plan.Remove, current.Previous.Path)
	}

	for _, path := range []string{current.DataDir, current.CacheDir} {
		if path != "" {
			plan.Remove = append(plan.Remove, path)
		}
	}

	if current.SelectionFile != "" {
		plan.Remove = append(plan.Remove, current.SelectionFile)
	}

	// The state directory holds install.json and goes last, so that until the
	// final step Chroma still has the map of what it was managing.
	if current.StateDir != "" {
		plan.Remove = append(plan.Remove, current.StateDir)
	}

	plan.Restore = current.UserBackup
	return plan
}

// Uninstall removes what Chroma made and gives back what it borrowed.
//
// The configuration is moved aside before anything is deleted, and stays there
// until the pre-Chroma configuration has been put back. Deleting first would
// mean a failed restore leaves the directory empty — no Chroma and no
// configuration either, which is worse than either outcome on its own.
func (i *Installer) Uninstall(paths Paths, current installstate.State) (Removal, error) {
	sink := i.Sink
	if sink == nil {
		sink = Discard{}
	}

	if err := RefuseSymlinkedConfiguration(current.ConfigDir); err != nil {
		return Removal{}, err
	}

	// The filesystem is consulted before the record is believed.
	repaired, why, err := ReconcileHandover(current)
	if err != nil {
		return Removal{}, err
	}
	if why != "" {
		sink.Emit(Event{Step: "reconcile", Status: StatusWarning, Message: why})
		if err := installstate.Write(paths.InstallState, repaired); err != nil {
			return Removal{}, fmt.Errorf("recording what an interrupted run had already done: %w", err)
		}
		current = repaired
	}

	plan := PlanUninstall(paths, current)
	removal := Removal{}

	// Nothing about giving somebody's data back begins before the intention to
	// do it is on disk. If this write fails the filesystem is untouched, which
	// is the whole point of putting it first.
	if current.Handover == installstate.HandoverHeld {
		beginning := current
		beginning.Handover = installstate.HandoverPending
		if err := installstate.Write(paths.InstallState, beginning); err != nil {
			return removal, fmt.Errorf("recording that the handover is starting: %w", err)
		}
		current = beginning
	}

	tx := NewTransaction(paths)

	// Held rather than removed. Until the restore below has succeeded this is
	// the only copy of anything at ConfigDir.
	// A configuration already handed back is not touched at all — not held, not
	// moved, not looked at for permission to move. It is somebody else's.
	if current.Handover != installstate.HandoverHandedBack {
		sink.Emit(Event{Step: "hold", Status: StatusStart})
		if _, err := os.Stat(current.ConfigDir); err == nil {
			if err := tx.BackupTarget(paths); err != nil {
				return removal, fmt.Errorf("moving %s aside: %w", current.ConfigDir, err)
			}
		} else if !errors.Is(err, os.ErrNotExist) {
			return removal, fmt.Errorf("looking at %s: %w", current.ConfigDir, err)
		}
	}

	// Everything up to the restore is undoable, so a failure here puts Chroma
	// back exactly as it was.
	if err := hit(faultAfterCurrentMoved); err != nil {
		return removal, undo(tx, err)
	}

	if plan.Restore != "" {
		sink.Emit(Event{Step: "restore", Status: StatusStart})
		if err := tx.RestoreGeneration(plan.Restore, paths); err != nil {
			// Put the Chroma configuration back and stop. Nothing has been
			// deleted, so this is recoverable by running the command again.
			return removal, undo(tx, fmt.Errorf("restoring the configuration that was here before Chroma: %w", err))
		}
		removal.Restored = plan.Restore
		sink.Emit(Event{Step: "restore", Status: StatusDone, Message: plan.Restore})
	}

	// **The commit point.**
	//
	// Before this line the operation is reversible: nothing has been deleted
	// and the user's own configuration is still where Chroma put it, so a
	// failure restores Chroma and asks to be run again.
	//
	// After it, ownership has changed hands. The directory now holds the
	// configuration its owner had before Chroma ever ran, and moving it a
	// second time to reinstate an installation somebody has just asked to
	// remove would be Chroma taking back something it has already given. So
	// from here nothing is undone — what is left is deletion of Chroma's own
	// paths, and every one of those is safe to attempt again. The record is
	// removed last precisely so that a second run still knows what to finish.
	held := tx.Backup
	tx.Commit()

	// Written down, not merely reasoned about. Until this line the record says
	// there is a configuration to give back; past it there is not, because it
	// has been given. A stop here without this write leaves a record pointing
	// at a directory whose contents have moved, and a second attempt then fails
	// trying to restore from somewhere empty — measured, by the fault point
	// below, before this line existed.
	//
	// A failure to write it is reported and does not stop the removals: they
	// are what was asked for, and the record is on its way out anyway.
	if err := hit(faultRestoredNotRecorded); err != nil {
		return removal, err
	}

	if plan.Restore != "" {
		handed := current
		handed.UserBackup = ""
		handed.Handover = installstate.HandoverHandedBack
		if err := installstate.Write(paths.InstallState, handed); err != nil {
			removal.Problems = append(removal.Problems,
				fmt.Errorf("recording that %s has been given back: %w", plan.Restore, err))
		}
	}

	if err := hit(faultAfterUserRestore); err != nil {
		return removal, err
	}

	sink.Emit(Event{Step: "remove", Status: StatusStart})
	for _, path := range plan.Remove {
		// The configuration itself was moved, not deleted; the held copy is
		// what goes.
		target := path
		if path == current.ConfigDir {
			if held == "" {
				continue
			}
			target = held
		}

		if err := os.RemoveAll(target); err != nil {
			removal.Problems = append(removal.Problems, fmt.Errorf("removing %s: %w", target, err))
			continue
		}
		removal.Removed = append(removal.Removed, path)
	}

	// The directory the selection lived in, if nothing else is in it. `Remove`
	// rather than `RemoveAll` on purpose: it succeeds only on an empty
	// directory, so anything somebody else put there keeps it — and Chroma has
	// no business deciding what that is. Left behind, this was the one thing a
	// real uninstall still left on the machine.
	if current.SelectionFile != "" {
		if err := os.Remove(filepath.Dir(current.SelectionFile)); err == nil {
			removal.Removed = append(removal.Removed, filepath.Dir(current.SelectionFile))
		}
	}

	sink.Emit(Event{Step: "uninstall", Status: StatusDone})
	return removal, errors.Join(removal.Problems...)
}
