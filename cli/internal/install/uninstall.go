package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

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

	// GiveBack are the directories Chroma borrowed and still owes, in the
	// order they are to be returned. Never on Remove: the Chroma directory
	// standing at each one's path is removed as part of giving it back, which
	// is a different act from deleting a path Chroma owns outright.
	GiveBack []installstate.Borrowed

	// RestoreTo is where the configuration goes.
	RestoreTo string
}

// giveBackOrder is the order borrowed directories are returned in.
//
// Configuration first, because it is the one whose return somebody would check,
// and state last: install.json lives under it, so once it has been given back
// there is no record left to write the next step into.
var giveBackOrder = []string{"configuration", "data", "cache", "state"}

// undo puts a half-done uninstall back, and reports both problems if the
// putting back is what failed.
func undo(tx *Transaction, cause error) error {
	if problem := tx.Rollback(); problem != nil {
		return errors.Join(cause, problem)
	}
	return cause
}

// ReconcileHandover repairs a record left behind by a process that stopped
// existing between giving a borrowed directory back and writing that down.
//
// A signal can land in that window; an error cannot, because the two statements
// are adjacent. What is left is a record saying "there is a directory to give
// back" and a filesystem saying the opposite, and the rule is that the
// filesystem wins — a record is a description, and a description that disagrees
// with the thing it describes is wrong about it.
//
// The inference is allowed only where the record says a handover had begun.
// `pending` is written before the first move, so its presence is Chroma's own
// record of having entered the transfer. That is the whole difference from the
// version H4 forged: with Chroma still installed, deleting the backup and one
// file out of the tree was enough to make the old rule conclude the
// configuration had been given back — because it asked what the directory
// looked like.
//
// What it asks now is not what the directory looks like but which directory it
// is. The recorded device and inode are the ones the borrowed directory had
// when Chroma took it, and a rename keeps both; so if the backup is gone and
// the original path holds that same inode, the rename ran and nothing else
// could have produced it. Shape could be imitated by anybody. This cannot be,
// except by the account owner rewriting install.json, which is outside the
// threat model either way.
//
// Anything else with `pending` set is a contradiction — the backup gone and
// nothing recognisable at the original path — and produces a refusal rather
// than a story.
//
// Returns the record to act on, a sentence for whoever is watching, and an
// error when nothing can be concluded safely.
func ReconcileHandover(current installstate.State) (installstate.State, string, error) {
	repaired := current
	repaired.Borrowed = append([]installstate.Borrowed(nil), current.Borrowed...)

	var said []string
	for index, borrowed := range repaired.Borrowed {
		if borrowed.Handover != installstate.HandoverPending {
			// Not in a transfer, so the state of the backup proves nothing
			// about ownership. A missing one is somebody else's doing and is
			// refused later, by name.
			continue
		}

		if _, err := os.Lstat(borrowed.Backup); err == nil {
			// Still there: the rename had not run, so the transfer resumes.
			continue
		}

		got, err := Identify(borrowed.Original)
		if err != nil {
			return current, "", fmt.Errorf(
				"a handover of your %s was interrupted: %s is no longer there and %s cannot be read, so this cannot tell where it went: %w",
				borrowed.Kind, borrowed.Backup, borrowed.Original, err)
		}
		if got != identityOfRecord(borrowed) {
			return current, "", fmt.Errorf(
				"a handover of your %s was interrupted: %s is no longer there and %s is not the directory Chroma moved aside, so the two do not add up",
				borrowed.Kind, borrowed.Backup, borrowed.Original)
		}

		repaired.Borrowed[index].Handover = installstate.HandoverHandedBack
		said = append(said, fmt.Sprintf("your %s at %s", borrowed.Kind, borrowed.Original))
	}

	if len(said) == 0 {
		return current, "", nil
	}
	return repaired, fmt.Sprintf(
		"An interrupted handover was found: %s had already been given back, and the record has been brought up to date.",
		strings.Join(said, ", ")), nil
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
// kind. Every directory `--default` took over is the second, and none of them
// is ever on the removal list.
//
// There are up to four of the second kind, not one. `~/.config/nvim` is the
// visible one; `~/.local/share/nvim`, `~/.local/state/nvim` and `~/.cache/nvim`
// are the ones Neovim reads without being asked, and an uninstall that listed
// them as Chroma's own removed somebody's plugins and undo history — measured,
// on a real machine.
func PlanUninstall(paths Paths, current installstate.State) RemovalPlan {
	plan := RemovalPlan{RestoreTo: current.ConfigDir}

	// borrowed, by the path it belongs at. A path in here is not Chroma's,
	// whatever stands there now and whichever list would otherwise claim it.
	borrowed := map[string]installstate.Borrowed{}
	for _, one := range current.Borrowed {
		borrowed[one.Original] = one
	}

	for _, kind := range giveBackOrder {
		for _, one := range current.Borrowed {
			if one.Kind == kind && one.Handover != installstate.HandoverHandedBack {
				plan.GiveBack = append(plan.GiveBack, one)
			}
		}
	}

	// ours reports whether a path is Chroma's to delete outright. A borrowed
	// one never is: either it is still owed, and the Chroma directory standing
	// there is removed as part of handing it back, or it has been handed back
	// already and holds somebody else's work.
	ours := func(path string) bool {
		if path == "" {
			return false
		}
		_, isBorrowed := borrowed[path]
		return !isBorrowed
	}

	// The order is the order they go in: the configuration first, then what it
	// left beside itself, and the record of all of it last.
	if ours(current.ConfigDir) {
		plan.Remove = append(plan.Remove, current.ConfigDir)
	}

	if current.Previous != nil && current.Previous.Path != "" && ours(current.Previous.Path) {
		plan.Remove = append(plan.Remove, current.Previous.Path)
	}

	for _, path := range []string{current.DataDir, current.CacheDir} {
		if ours(path) {
			plan.Remove = append(plan.Remove, path)
		}
	}

	if current.SelectionFile != "" {
		plan.Remove = append(plan.Remove, current.SelectionFile)
	}

	// The state directory holds install.json and goes last, so that until the
	// final step Chroma still has the map of what it was managing.
	if ours(current.StateDir) {
		plan.Remove = append(plan.Remove, current.StateDir)
	}

	return plan
}

// Uninstall removes what Chroma made and gives back what it borrowed.
//
// Each borrowed directory is given back the same way: Chroma's own directory at
// that path is moved aside, the borrowed one is proved to be the one that was
// taken, and only then does it move home. Chroma's copy is deleted afterwards.
// Deleting first would mean a failed restore leaves the path empty — no Chroma
// and nothing of the user's either, which is worse than either outcome alone.
//
// The configuration is the commit point, and the rest follow it. Up to the
// moment somebody's own `init.lua` is back at `~/.config/nvim` this is
// reversible and a failure reinstates Chroma; past it, ownership has changed
// hands, and a failure to hand back the data directory is reported and resumed
// rather than undone. Undoing it would mean taking back something already
// given.
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
		if written, err := writeRecord(paths.InstallState, repaired); err != nil && !written.Replaced {
			return Removal{}, fmt.Errorf("recording what an interrupted run had already done: %w", err)
		}
		current = repaired
	}

	plan := PlanUninstall(paths, current)
	removal := Removal{}

	// Nothing about giving somebody's directories back begins before the
	// intention to do it is on disk. If this write fails the filesystem is
	// untouched, which is the whole point of putting it first.
	//
	// Every one of them at once, not one at a time: they were taken together
	// and the record has to be able to say so before the first rename, or a
	// process that stops after two of four leaves two directories nobody can
	// prove were ever in transit.
	//
	// Before the protocol starts, not merely before the move: once Chroma
	// cannot show that what sits at a recorded path is the directory it put
	// there, it has no business beginning a transfer of ownership at all.
	if beginning, entered := beginHandover(current, plan); entered {
		for _, one := range plan.GiveBack {
			if err := ProveIdentity(one.Backup, identityOfRecord(one), "your "+one.Kind); err != nil {
				return removal, err
			}
		}
		// Replaced is what matters: if the intention reached the disk, the
		// protocol has begun whether or not the flush was confirmed. Refusing
		// to continue then would leave `pending` recorded with nothing to
		// resume from.
		if written, err := writeRecord(paths.InstallState, beginning); err != nil && !written.Replaced {
			return removal, fmt.Errorf("recording that the handover is starting: %w", err)
		}
		current = beginning
	}

	tx := NewTransaction(paths)

	// Chroma's own directories that were moved out of the way, and where they
	// went. They are removed at the end like anything else Chroma owns — the
	// difference is only that the path they used to have now belongs to
	// somebody else, so the copy is what goes and the original is what is
	// reported.
	type doomed struct{ report, target string }
	var held []doomed

	// Held rather than removed. Until the restore below has succeeded this is
	// the only copy of anything at ConfigDir.
	// A configuration already handed back is not touched at all — not held, not
	// moved, not looked at for permission to move. It is somebody else's.
	if ownsConfigDir(current) {
		sink.Emit(Event{Step: "hold", Status: StatusStart})
		moved, err := tx.HoldAside(current.ConfigDir)
		if err != nil {
			return removal, fmt.Errorf("moving %s aside: %w", current.ConfigDir, err)
		}
		if moved != "" {
			held = append(held, doomed{report: current.ConfigDir, target: moved})
		}
	}

	// Everything up to the restore is undoable, so a failure here puts Chroma
	// back exactly as it was.
	if err := hit(faultAfterCurrentMoved); err != nil {
		return removal, undo(tx, err)
	}

	// The configuration, on its own and first, because it is the commit point.
	if configuration, found := firstOfKind(plan.GiveBack, "configuration"); found {
		sink.Emit(Event{Step: "restore", Status: StatusStart})
		want := identityOfRecord(configuration)
		if err := tx.RestoreGeneration(configuration.Backup, want, paths); err != nil {
			// Put the Chroma configuration back and stop. Nothing has been
			// deleted, so this is recoverable by running the command again.
			return removal, undo(tx, fmt.Errorf("restoring the configuration that was here before Chroma: %w", err))
		}
		removal.Restored = configuration.Backup
		sink.Emit(Event{Step: "restore", Status: StatusDone, Message: configuration.Backup})
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
	// paths and the return of the remaining borrowed ones, and every one of
	// those is safe to attempt again. The record is removed last precisely so
	// that a second run still knows what to finish.
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

	if removal.Restored != "" {
		current = markHandedBack(current, "configuration")
		if written, err := writeRecord(paths.InstallState, current); err != nil && !written.Replaced {
			removal.Problems = append(removal.Problems,
				fmt.Errorf("recording that %s has been given back: %w", removal.Restored, err))
		}
	}

	if err := hit(faultAfterUserRestore); err != nil {
		return removal, err
	}

	// The rest of what was borrowed: data, cache, and state last. Each is a
	// separate resumable step — a failure on one is reported and the next is
	// still attempted, because they are independent directories and giving two
	// of three back beats giving none.
	for _, one := range plan.GiveBack {
		if one.Kind == "configuration" {
			continue
		}

		moved, err := tx.HoldAside(one.Original)
		if err != nil {
			removal.Problems = append(removal.Problems, fmt.Errorf("giving your %s back: %w", one.Kind, err))
			continue
		}

		want := identityOfRecord(one)
		if err := ProveIdentity(one.Backup, want, "your "+one.Kind); err != nil {
			removal.Problems = append(removal.Problems, err)
			// Chroma's own directory goes back where it was, so the path is not
			// left empty because of a refusal.
			if moved != "" {
				if putBack := os.Rename(moved, one.Original); putBack != nil {
					removal.Problems = append(removal.Problems, fmt.Errorf("putting %s back as %s: %w", moved, one.Original, putBack))
				}
			}
			continue
		}
		if err := os.Rename(one.Backup, one.Original); err != nil {
			removal.Problems = append(removal.Problems, describeRestoreFailure(one.Backup, one.Original, err))
			continue
		}
		sink.Emit(Event{Step: "restore", Status: StatusDone, Message: one.Kind + ": " + one.Original})

		// The Chroma directory that stood there is gone now, and the record has
		// to stop claiming the borrowed one is still held.
		//
		// State is the exception, and deliberately: install.json lives under
		// it, so by this point the record has moved with the held copy and
		// writing to paths.InstallState would create a fresh directory in the
		// one just handed back. Its copy is removed instead, immediately, which
		// is what finishing the uninstall would do anyway.
		current = markHandedBack(current, one.Kind)
		if one.Kind == "state" {
			if moved != "" {
				if err := os.RemoveAll(moved); err != nil {
					removal.Problems = append(removal.Problems, fmt.Errorf("removing %s: %w", moved, err))
				}
			}
			continue
		}

		if moved != "" {
			held = append(held, doomed{report: one.Original, target: moved})
		}
		if written, err := writeRecord(paths.InstallState, current); err != nil && !written.Replaced {
			removal.Problems = append(removal.Problems,
				fmt.Errorf("recording that your %s has been given back: %w", one.Kind, err))
		}
	}

	sink.Emit(Event{Step: "remove", Status: StatusStart})

	// Chroma's own paths, and then the copies of the ones whose place has been
	// given back. Both are Chroma's; only the second kind no longer lives where
	// its name says, which is why it is reported under the path it had.
	going := make([]doomed, 0, len(plan.Remove)+len(held))
	for _, path := range plan.Remove {
		going = append(going, doomed{report: path, target: path})
	}
	going = append(going, held...)

	for _, one := range going {
		if err := os.RemoveAll(one.target); err != nil {
			removal.Problems = append(removal.Problems, fmt.Errorf("removing %s: %w", one.target, err))
			continue
		}
		removal.Removed = append(removal.Removed, one.report)
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

// beginHandover marks every directory still owed as being in transit.
func beginHandover(current installstate.State, plan RemovalPlan) (installstate.State, bool) {
	if len(plan.GiveBack) == 0 {
		return current, false
	}

	beginning := current
	beginning.Borrowed = append([]installstate.Borrowed(nil), current.Borrowed...)
	for index, one := range beginning.Borrowed {
		if one.Handover == installstate.HandoverHeld {
			beginning.Borrowed[index].Handover = installstate.HandoverPending
		}
	}
	return beginning, true
}

// markHandedBack records that one borrowed directory is somebody else's again.
func markHandedBack(current installstate.State, kind string) installstate.State {
	updated := current
	updated.Borrowed = append([]installstate.Borrowed(nil), current.Borrowed...)
	for index, one := range updated.Borrowed {
		if one.Kind == kind {
			updated.Borrowed[index].Handover = installstate.HandoverHandedBack
		}
	}
	return updated
}

// ownsConfigDir reports whether the configuration directory is Chroma's to move.
func ownsConfigDir(current installstate.State) bool {
	for _, one := range current.Borrowed {
		if one.Original == current.ConfigDir && one.Handover == installstate.HandoverHandedBack {
			return false
		}
	}
	return true
}

// firstOfKind finds one borrowed directory by what it is.
func firstOfKind(borrowed []installstate.Borrowed, kind string) (installstate.Borrowed, bool) {
	for _, one := range borrowed {
		if one.Kind == kind {
			return one, true
		}
	}
	return installstate.Borrowed{}, false
}
