package install

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// present reports whether a path is there at all. Lstat rather than Stat: a
// dangling symlink is something, and recovery has to know it is there before it
// decides anything about it.
func present(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

// backupMark and provisionalMark are the two names recovery reasons about.
const (
	backupMark      = ".chroma-backup-"
	provisionalMark = ".chroma-provisional-"
)

// Interruption is a generation transaction that stopped between moving a
// directory and writing the record.
//
// It is detected rather than journalled, because the evidence is already
// durable: **a `*.chroma-backup-*` directory the record does not reference
// cannot exist in any committed state.** An installation records what it moved
// aside as `user_backup`; an update and a rollback record it as
// `previous.path`. One that nothing points at is proof that a process died
// between its backup step and its commit — which is exactly the window writing
// the record last does not cover, because the write never happens.
type Interruption struct {
	// Orphan is the unreferenced backup: the generation that was committed.
	Orphan string

	// Displaced is what sits at the target now and was never committed, or ""
	// when the target is empty. It is moved aside before anything is restored
	// and removed only afterwards.
	Displaced string

	// ReturnTo is where the directory currently at the target belongs. Set only
	// for an interrupted rollback, where the target holds the generation the
	// record still calls previous.
	ReturnTo string

	// Why is a sentence for whoever is watching.
	Why string
}

// DetectInterruption looks for an unfinished generation transaction.
//
// It concludes only what it can show. Anything ambiguous — more than one
// orphan, an orphan that is not a Chroma tree, a recorded previous that is
// missing with nothing to explain it — returns an error rather than a guess:
// the alternative is a recovery that moves somebody's directories on a hunch.
func DetectInterruption(paths Paths, current installstate.State) (*Interruption, error) {
	beside := filepath.Dir(paths.ConfigDir)
	entries, err := os.ReadDir(beside)
	if err != nil {
		return nil, fmt.Errorf("looking beside %s: %w", paths.ConfigDir, err)
	}

	referenced := map[string]bool{}
	if current.Previous != nil && current.Previous.Path != "" {
		referenced[current.Previous.Path] = true
	}
	if current.UserBackup != "" {
		referenced[current.UserBackup] = true
	}

	var orphans []string
	base := filepath.Base(paths.ConfigDir)
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasPrefix(name, base+backupMark) {
			continue
		}
		path := filepath.Join(beside, name)
		if !referenced[path] {
			orphans = append(orphans, path)
		}
	}

	previousMissing := current.Previous != nil && current.Previous.Path != "" &&
		!present(current.Previous.Path)
	targetMissing := !present(paths.ConfigDir)

	switch {
	case len(orphans) == 0 && !previousMissing:
		return nil, nil

	case len(orphans) == 0:
		// The record points at a generation that is not there and nothing
		// explains where it went.
		return nil, fmt.Errorf(
			"%s records a previous generation at %s, which is not there, and there is no interrupted transaction to explain it",
			paths.InstallState, current.Previous.Path)

	case len(orphans) > 1:
		return nil, fmt.Errorf(
			"there are %d unreferenced Chroma backups beside %s and no way to tell which belongs to an interrupted transaction:\n  %s",
			len(orphans), paths.ConfigDir, strings.Join(orphans, "\n  "))
	}

	orphan := orphans[0]
	// The same check every other use of a recorded path gets. `isChromaTree`
	// follows links, so without this a link pointing at anything
	// configuration-shaped would have been renamed into the target and recorded
	// as the committed generation.
	if err := RefuseSubstituted(orphan); err != nil {
		return nil, err
	}
	if !isChromaTree(orphan) {
		return nil, fmt.Errorf("%s is not a Chroma configuration, so it cannot be the generation to restore", orphan)
	}

	// An unreferenced backup is evidence of an interrupted transaction only
	// where its presence closes a gap in the committed state. With the target in
	// place and every recorded path where the record says it is, nothing is
	// missing — so the directory beside them explains nothing, and a familiar
	// name is not proof of ownership.
	//
	// Measured, and it is why this exists: without the check, a stray
	// `*.chroma-backup-*` was treated as the committed generation, moved over a
	// perfectly good installation, and the good one deleted.
	//
	// The honest cost is that an update killed between placing the new tree and
	// writing the record is no longer distinguished from a complete state with a
	// stray directory beside it. From the filesystem alone the two are the same
	// arrangement, and inventing a rule that told them apart would be inventing
	// a fact. So that case is reported and refused rather than guessed at.
	if !targetMissing && !previousMissing {
		return nil, fmt.Errorf(
			"%s is a Chroma backup that nothing in %s refers to, and the installation is otherwise complete.\nIt may be what an interrupted update left behind, or something copied there; this cannot tell which and will not guess.\nMove it away or delete it, and run this again",
			orphan, paths.InstallState)
	}

	found := &Interruption{Orphan: orphan}

	if previousMissing {
		// An interrupted rollback: the target holds what the record still calls
		// the previous generation, and the orphan holds what it calls current.
		// Both go back where the record says they are.
		if !present(paths.ConfigDir) {
			return nil, fmt.Errorf(
				"%s records a previous generation at %s, which is not there, and %s is empty",
				paths.InstallState, current.Previous.Path, paths.ConfigDir)
		}
		found.ReturnTo = current.Previous.Path
		found.Why = fmt.Sprintf(
			"An interrupted rollback was found. %s is being put back as the installed generation and %s returned to %s; the record already describes that arrangement.",
			describeVersionOfGeneration(current.Version), paths.ConfigDir, current.Previous.Path)
		return found, nil
	}

	// An interrupted install or update: the orphan is the committed generation
	// and anything at the target was never committed.
	if present(paths.ConfigDir) {
		found.Displaced = paths.ConfigDir
	}
	found.Why = fmt.Sprintf(
		"An interrupted transaction was found. Restoring the last committed generation %s; what was placed at %s was never recorded and is being removed.",
		describeVersionOfGeneration(current.Version), paths.ConfigDir)
	return found, nil
}

// Repair puts the committed arrangement back.
//
// Renames first and deletion last, always. A recovery that removed the
// uncommitted tree and then failed to move the committed one into place would
// leave a machine with no configuration at all — the same hole it exists to
// close, dug one level down.
func (found *Interruption) Repair(paths Paths) error {
	// Anything at the target that was never committed goes aside, under a name
	// that is not a backup: a second `*.chroma-backup-*` would make the next
	// detection ambiguous and refuse.
	aside := ""
	if found.Displaced != "" {
		aside = paths.ConfigDir + provisionalMark + now().Format("20060102T150405Z")
		if err := os.Rename(found.Displaced, aside); err != nil {
			return fmt.Errorf("moving the uncommitted configuration at %s aside: %w", found.Displaced, err)
		}
	}

	if found.ReturnTo != "" {
		if err := os.Rename(paths.ConfigDir, found.ReturnTo); err != nil {
			return fmt.Errorf("returning %s to %s: %w", paths.ConfigDir, found.ReturnTo, err)
		}
	}

	if err := hit(faultDuringRepair); err != nil {
		return errors.Join(err, putBack(paths, aside))
	}

	if err := os.Rename(found.Orphan, paths.ConfigDir); err != nil {
		// The target is empty and the committed generation would not move.
		// Whatever was here is worth more than nothing, so it goes back.
		return errors.Join(
			fmt.Errorf("restoring %s as %s: %w", found.Orphan, paths.ConfigDir, err),
			putBack(paths, aside))
	}

	// Only now, with the committed arrangement back, is anything removed. A
	// provisional tree is by definition one no record ever described, and this
	// sweeps any left by an earlier recovery that was itself interrupted.
	return sweepProvisional(paths)
}

// putBack returns the uncommitted tree to the target when the committed one
// could not be restored.
//
// This is what makes the ordering load-bearing rather than merely tidy. Moving
// the uncommitted tree aside instead of deleting it costs one rename, and buys
// the difference between "the machine still has a configuration, and it is not
// the one recorded" and "the machine has none at all".
func putBack(paths Paths, aside string) error {
	if aside == "" || present(paths.ConfigDir) {
		return nil
	}
	if err := os.Rename(aside, paths.ConfigDir); err != nil {
		return fmt.Errorf("putting %s back at %s: %w", aside, paths.ConfigDir, err)
	}
	return nil
}

// sweepProvisional removes trees an interrupted recovery left aside.
func sweepProvisional(paths Paths) error {
	beside := filepath.Dir(paths.ConfigDir)
	entries, err := os.ReadDir(beside)
	if err != nil {
		return fmt.Errorf("looking beside %s: %w", paths.ConfigDir, err)
	}

	base := filepath.Base(paths.ConfigDir)
	var problems []string
	for _, entry := range entries {
		if !strings.HasPrefix(entry.Name(), base+provisionalMark) {
			continue
		}
		if err := os.RemoveAll(filepath.Join(beside, entry.Name())); err != nil {
			problems = append(problems, err.Error())
		}
	}
	if len(problems) > 0 {
		return fmt.Errorf("removing uncommitted configurations: %s", strings.Join(problems, "; "))
	}
	return nil
}

func describeVersionOfGeneration(version string) string {
	if version == "" {
		return "the installation from a checkout"
	}
	return version
}

// Recover detects an interrupted transaction and puts the committed
// arrangement back, reporting what it did.
//
// Nothing is asked of the user. Whether a half-placed tree had been
// bootstrapped or verified is not something anybody outside this process can
// know, and offering it as a choice would be a way of promoting an uncommitted
// transaction. Either the committed state can be shown and is restored, or it
// cannot and nothing is touched.
func Recover(paths Paths, current installstate.State) (string, error) {
	found, err := DetectInterruption(paths, current)
	if err != nil {
		return "", err
	}
	if found == nil {
		// Even with nothing to recover, a provisional tree from an interrupted
		// recovery is worth removing.
		return "", sweepProvisional(paths)
	}
	if err := found.Repair(paths); err != nil {
		return "", err
	}
	return found.Why, nil
}
