package install

import (
	"errors"
	"fmt"
	"os"

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
	plan.Remove = append(plan.Remove, current.ConfigDir)

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

	plan := PlanUninstall(paths, current)
	removal := Removal{}

	tx := NewTransaction(paths)

	// Held rather than removed. Until the restore below has succeeded this is
	// the only copy of anything at ConfigDir.
	sink.Emit(Event{Step: "hold", Status: StatusStart})
	if _, err := os.Stat(current.ConfigDir); err == nil {
		if err := tx.BackupTarget(paths); err != nil {
			return removal, fmt.Errorf("moving %s aside: %w", current.ConfigDir, err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return removal, fmt.Errorf("looking at %s: %w", current.ConfigDir, err)
	}

	if plan.Restore != "" {
		sink.Emit(Event{Step: "restore", Status: StatusStart})
		if err := tx.RestoreGeneration(plan.Restore, paths); err != nil {
			// Put the Chroma configuration back and stop. Nothing has been
			// deleted, so this is recoverable by running the command again.
			if problem := tx.Rollback(); problem != nil {
				return removal, errors.Join(err, problem)
			}
			return removal, fmt.Errorf("restoring the configuration that was here before Chroma: %w", err)
		}
		removal.Restored = plan.Restore
		sink.Emit(Event{Step: "restore", Status: StatusDone, Message: plan.Restore})
	}

	// Past here nothing is put back, so the transaction is closed before the
	// first delete rather than after the last: a Rollback() from this point
	// would restore a Chroma that is half removed.
	held := tx.Backup
	tx.Commit()

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

	sink.Emit(Event{Step: "uninstall", Status: StatusDone})
	return removal, errors.Join(removal.Problems...)
}
