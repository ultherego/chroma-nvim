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
	// rather than stopping: refusing to remove the rest would leave more
	// behind than carrying on does.
	Problems []error
}

// RemovalPlan is everything an uninstall would touch, worked out before it touches
// anything.
type RemovalPlan struct {
	// Remove are Chroma's own paths, which it made and may take away.
	Remove []string

	// GiveBack are the directories Chroma borrowed and still owes, in the order
	// they are to be returned. Never on Remove: the Chroma directory standing
	// at each path is removed as part of giving it back.
	GiveBack []installstate.Borrowed

	// RestoreTo is where the configuration goes.
	RestoreTo string
}

// giveBackOrder is the order borrowed directories are returned in.
// Configuration first, because that is the return somebody would check, and
// state last: install.json lives under it.
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
// existing between giving a borrowed directory back and writing that down. The
// filesystem wins: a record is a description, and one that disagrees with what
// it describes is wrong about it.
//
// Allowed only where the record says a handover had begun. What it asks is not
// what the directory looks like but which directory it is — the recorded device
// and inode are what the borrowed directory had when Chroma took it, and a
// rename keeps both. That is the whole difference from the version H4 forged.
//
// Anything else with `pending` set is a contradiction and produces a refusal.
func ReconcileHandover(current installstate.State) (installstate.State, string, error) {
	repaired := current
	repaired.Borrowed = append([]installstate.Borrowed(nil), current.Borrowed...)

	var said []string
	for index, borrowed := range repaired.Borrowed {
		if borrowed.Handover != installstate.HandoverPending {
			// Not in a transfer, so the state of the backup proves nothing about
			// ownership. A missing one is refused later, by name.
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

// isChromaTree reports whether a directory holds a Chroma configuration: the
// same file LocalSource insists on before it will install anything.
func isChromaTree(dir string) bool {
	_, err := os.Stat(filepath.Join(dir, "lua", "chroma", "bootstrap.lua"))
	return err == nil
}

// RefuseSymlinkedConfiguration reports why a symlinked configuration cannot be
// uninstalled.
//
// Renaming a symlink moves the link and removing it removes the link. Measured,
// not imagined: an uninstall that did that deleted the link, left nine entries
// behind and said "6 paths removed". Following it is worse — the README's own
// second installation route links to a checkout with somebody's work in it.
//
// Exported because the refusal has to happen before the plan is printed, and
// the check still runs inside Uninstall so no caller can skip it.
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

// PlanUninstall works out what an uninstall would do, under a single rule:
// **what Chroma made for its own operation it may remove; what Chroma only
// moved aside it gives back.**
//
// There are up to four of the second kind. `~/.config/nvim` is the visible one;
// `~/.local/share/nvim`, `~/.local/state/nvim` and `~/.cache/nvim` are the ones
// Neovim reads without being asked, and an uninstall that listed them as
// Chroma's own removed somebody's plugins and undo history — measured.
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
// Each borrowed directory is given back the same way: Chroma's own directory
// there is moved aside, the borrowed one is proved to be the one that was
// taken, and only then does it move home. Deleting Chroma's copy first would
// mean a failed restore leaves the path empty.
//
// The configuration is the commit point. Up to the moment somebody's own
// `init.lua` is back this is reversible; past it, ownership has changed hands,
// and a failure on the rest is reported and resumed rather than undone.
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

	// Nothing begins before the intention to do it is on disk, and all of them
	// at once: they were taken together, and a process that stops after two of
	// four would leave two directories nobody can prove were in transit. Before
	// the protocol starts, not merely before the move — once Chroma cannot show
	// that what sits at a recorded path is what it put there, it has no business
	// beginning a transfer of ownership.
	if beginning, entered := beginHandover(current, plan); entered {
		for _, one := range plan.GiveBack {
			if err := ProveIdentity(one.Backup, identityOfRecord(one), "your "+one.Kind); err != nil {
				return removal, err
			}
		}
		// Replaced is what matters: if the intention reached the disk the
		// protocol has begun, and refusing to continue would leave `pending`
		// recorded with nothing to resume from.
		if written, err := writeRecord(paths.InstallState, beginning); err != nil && !written.Replaced {
			return removal, fmt.Errorf("recording that the handover is starting: %w", err)
		}
		current = beginning
	}

	tx := NewTransaction(paths)

	// Chroma's own directories that were moved out of the way, and where they
	// went. Removed at the end like anything else Chroma owns; the difference
	// is that their old path now belongs to somebody else, so the copy goes and
	// the original path is what gets reported.
	type doomed struct{ report, target string }
	var held []doomed

	// Held rather than removed: until the restore succeeds this is the only
	// copy of anything at ConfigDir. A configuration already handed back is not
	// touched at all — it is somebody else's.
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
			// Nothing has been deleted, so running the command again recovers.
			return removal, undo(tx, fmt.Errorf("restoring the configuration that was here before Chroma: %w", err))
		}
		removal.Restored = configuration.Backup
		sink.Emit(Event{Step: "restore", Status: StatusDone, Message: configuration.Backup})
	}

	// **The commit point.** Before this line nothing has been deleted and a
	// failure restores Chroma. After it the directory holds the configuration
	// its owner had before Chroma ever ran, and moving it again would be Chroma
	// taking back what it has given — so from here nothing is undone. What is
	// left is safe to attempt again, and the record is removed last precisely
	// so that a second run knows what to finish.
	tx.Commit()

	// Written down, not merely reasoned about: past this line the record must
	// not say there is a configuration to give back. Measured by the fault point
	// below, before this existed: a stop here left a record pointing at a
	// directory whose contents had moved, and the second attempt failed
	// restoring from somewhere empty. A failed write is reported and does not
	// stop the removals.
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
	// separate resumable step, because giving two of three back beats none.
	for _, one := range plan.GiveBack {
		if one.Kind == "configuration" {
			continue
		}
		if one.Kind == "state" {
			// The terminal resource, and it waits for phase three: install.json
			// lives under it, so handing it back is the moment Chroma stops
			// having a record. Measured, before this: the cache could not be
			// handed back, the state went home anyway, and the record with it.
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
			// Chroma's own directory goes back, so a refusal does not leave the
			// path empty.
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

		// The Chroma directory that stood there is gone, so the record must stop
		// claiming the borrowed one is held. State is the exception: install.json
		// lives under it, so the record has moved with the held copy and writing
		// to paths.InstallState would create a directory in the one just handed
		// back. Its copy is removed immediately instead.
		current = markHandedBack(current, one.Kind)

		if moved != "" {
			held = append(held, doomed{report: one.Original, target: moved})
		}
		if written, err := writeRecord(paths.InstallState, current); err != nil && !written.Replaced {
			removal.Problems = append(removal.Problems,
				fmt.Errorf("recording that your %s has been given back: %w", one.Kind, err))
		}
	}

	sink.Emit(Event{Step: "remove", Status: StatusStart})

	// Chroma's own paths, then the copies of the ones whose place has been
	// given back; the second kind is reported under the path it had. The state
	// directory is held back — install.json lives there, so removing it is the
	// last act of an uninstall. See finish below.
	going := make([]doomed, 0, len(plan.Remove)+len(held))
	for _, path := range plan.Remove {
		if path == current.StateDir {
			continue
		}
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
	// rather than `RemoveAll`: it succeeds only on an empty directory, so
	// anything somebody else put there keeps it.
	if current.SelectionFile != "" {
		if err := os.Remove(filepath.Dir(current.SelectionFile)); err == nil {
			removal.Removed = append(removal.Removed, filepath.Dir(current.SelectionFile))
		}
	}

	// **The end of phase two, and the gate into phase three.** Everything above
	// can be attempted again, so if any of it failed the record stays where it
	// is and this stops — the record is the only description of what is left to
	// finish, and the next step destroys it.
	//
	// Measured before this gate existed: the state directory went while the
	// data directory could not be removed, and a second run answered "No Chroma
	// installation is recorded".
	if len(removal.Problems) > 0 {
		sink.Emit(Event{Step: "uninstall", Status: StatusFailed,
			Message: "some of what Chroma made could not be removed; the record is kept so this can be run again"})
		return removal, errors.Join(removal.Problems...)
	}

	if problems := finish(paths, current, plan, sink); len(problems) > 0 {
		removal.Problems = append(removal.Problems, problems...)
		return removal, errors.Join(removal.Problems...)
	}
	removal.Removed = append(removal.Removed, current.StateDir)

	sink.Emit(Event{Step: "uninstall", Status: StatusDone})
	return removal, errors.Join(removal.Problems...)
}

// finish is the last act of an uninstall, and the only one that destroys the
// record. Two shapes, one meaning: an installation of its own owns its state
// directory, so removing it is the commit; a takeover gives it back, and
// Chroma's copy — where install.json has been all along — goes immediately
// after. Nothing reaches here while anything else is unfinished.
func finish(paths Paths, current installstate.State, plan RemovalPlan, sink ProgressSink) []error {
	borrowed, owed := firstOfKind(plan.GiveBack, "state")
	if !owed {
		if err := os.RemoveAll(current.StateDir); err != nil {
			return []error{fmt.Errorf("removing %s: %w", current.StateDir, err)}
		}
		return nil
	}

	tx := NewTransaction(paths)
	moved, err := tx.HoldAside(borrowed.Original)
	if err != nil {
		return []error{fmt.Errorf("giving your %s back: %w", borrowed.Kind, err)}
	}

	if err := ProveIdentity(borrowed.Backup, identityOfRecord(borrowed), "your "+borrowed.Kind); err != nil {
		if moved != "" {
			if putBack := os.Rename(moved, borrowed.Original); putBack != nil {
				return []error{err, fmt.Errorf("putting %s back as %s: %w", moved, borrowed.Original, putBack)}
			}
		}
		return []error{err}
	}
	if err := os.Rename(borrowed.Backup, borrowed.Original); err != nil {
		if moved != "" {
			_ = os.Rename(moved, borrowed.Original)
		}
		return []error{describeRestoreFailure(borrowed.Backup, borrowed.Original, err)}
	}
	sink.Emit(Event{Step: "restore", Status: StatusDone, Message: borrowed.Kind + ": " + borrowed.Original})

	// The record went with it. Removing Chroma's copy is what makes the
	// uninstall complete, and there is deliberately nothing after this line.
	if moved != "" {
		if err := os.RemoveAll(moved); err != nil {
			return []error{fmt.Errorf("removing %s: %w", moved, err)}
		}
	}
	return nil
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
