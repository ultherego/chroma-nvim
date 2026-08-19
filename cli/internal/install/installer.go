package install

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
	"github.com/ultherego/chroma-nvim/cli/internal/theme"
)

// Installer carries out an installation. The interactive flow, the flag flow and
// update all go through this one function, because a second implementation is a
// second set of orderings to get right and the ordering is the whole design.
type Installer struct {
	Runner Runner
	Sink   ProgressSink
}

// Result is what happened, returned on failure as well as on success: whether
// the machine is back the way it was is most worth knowing when it did not work.
type Result struct {
	Paths    Paths
	Selected []string
	Enabled  []string
	State    installstate.State

	// Recorded says whether install.json was written, which is the only
	// difference between a managed installation and a directory that looks like
	// one.
	Recorded bool

	// RolledBack says an attempt was made to put the machine back, and
	// RollbackProblem says it did not entirely work. The second is the one to
	// print loudly.
	RolledBack      bool
	RollbackProblem error
}

// Apply runs the installation, and undoes it if any step fails.
//
// The order is the design, and it is this way round for reasons that are each
// somebody's bad afternoon:
//
//	selection   written first, so what runs is decided before anything runs
//	stage       assembled beside the target, complete before the target is touched
//	backup      a rename, so the old configuration cannot be half-moved
//	place       one rename, so there is no moment with half a configuration
//	bootstrap   plugins, tools and parsers, in the tree that was just placed
//	verify      is this a Chroma that starts, and the one that was asked for
//	record      last, because state that was never verified is worse than none
func (i *Installer) Apply(
	ctx context.Context,
	opts Options,
	paths Paths,
	prepared PreparedSource,
	set component.Set,
) (Result, error) {
	needsBackup, err := CheckTarget(paths)
	if err != nil {
		return Result{Paths: paths}, err
	}

	selected, err := opts.Selection(set)
	if err != nil {
		return Result{Paths: paths}, err
	}

	// Read from the tree that is about to be placed, not taken from the caller.
	// What a release can draw is the release's own fact, and an installer that
	// took somebody's word for it could write a choice the editor will not
	// honour — which is the one failure this document exists to prevent.
	catalogue, _, err := theme.LoadCatalogue(prepared.Root)
	if err != nil {
		return Result{Paths: paths}, err
	}
	chosen, err := opts.ThemeChoice(catalogue)
	if err != nil {
		return Result{Paths: paths}, err
	}

	return i.carryOut(ctx, paths, prepared, set, selected, chosen, catalogue, needsBackup, nil, nil)
}

// Update replaces a managed installation with another release, keeping the
// components its owner already chose. The same transaction as an installation,
// deliberately: a second path to placing a tree is a second installer, and the
// half nobody exercises daily is the half that breaks. Three things differ, all
// decided before this is called — the selection comes from the installation, the
// backup is not optional, and what was moved aside is recorded as a generation.
func (i *Installer) Update(
	ctx context.Context,
	paths Paths,
	prepared PreparedSource,
	set component.Set,
	selected []string,
	current installstate.State,
) (Result, error) {
	previous := &installstate.Generation{
		Version:     current.Version,
		Contract:    current.Contract,
		InstalledAt: current.InstalledAt,
		Source:      current.Source,
	}

	// false, not true: an update moves Chroma's own tree aside, which is what
	// `previous` says, while borrowing is what a takeover does to directories
	// that were never Chroma's. One boolean used to mean both, and that is how
	// an update came to look like a first takeover to everything downstream.
	//
	// The empty theme is the fourth thing that differs and is the same idea as
	// the third: an update carries a decision forward rather than making it
	// again. A release that dropped the colourscheme somebody picked leaves the
	// document naming it alone, and the editor says so at startup.
	return i.carryOut(ctx, paths, prepared, set, selected, "", theme.Catalogue{}, false, previous, current.Borrowed)
}

// Reconfigure changes which components are enabled, and nothing else.
//
// **It does not make a generation.** A generation is a release; which parts of
// it somebody wants is a different fact with a different lifetime, and
// conflating them would mean a rollback undid a preference. So there is no
// staging, no backup and no install.json written.
//
// It keeps the same transaction discipline: the new selection is written, the
// editor is brought to it, the result is verified, and only then is the change
// kept — so a mistyped component does not cost somebody their editor.
func (i *Installer) Reconfigure(
	ctx context.Context,
	paths Paths,
	set component.Set,
	selected []string,
) (Result, error) {
	sink := i.Sink
	if sink == nil {
		sink = Discard{}
	}

	result := Result{Paths: paths}
	result.Selected = selected
	result.Enabled = state.State{Schema: state.Schema, Selected: selected}.Enabled(set)

	tx := NewTransaction(paths)

	fail := func(step string, cause error) (Result, error) {
		sink.Emit(Event{Step: step, Status: StatusFailed, Message: cause.Error()})

		result.RolledBack = true
		if problem := tx.Rollback(); problem != nil {
			result.RollbackProblem = problem
		}
		return result, cause
	}

	sink.Emit(Event{Step: "selection", Status: StatusStart})
	if err := tx.WriteSelection(selected, set); err != nil {
		return fail("selection", err)
	}

	if err := tx.Bootstrap(ctx, paths, i.Runner, sink); err != nil {
		return fail("bootstrap", err)
	}
	if err := hit(faultAfterBootstrap); err != nil {
		return fail("bootstrap", err)
	}

	if err := tx.Verify(ctx, paths, result.Enabled, i.Runner, sink); err != nil {
		return fail("verify", err)
	}
	// The selection is written but not yet kept: a stop here has to leave the
	// one that was in force before.
	if err := hit(faultAfterVerify); err != nil {
		return fail("verify", err)
	}

	tx.Commit()
	sink.Emit(Event{Step: "components", Status: StatusDone})
	return result, nil
}

// Rollback puts the previous generation back, and keeps the current selection:
// what somebody wants is not undone by moving the version. The caller has
// already checked that the selection is legal in the generation being restored.
//
// It swaps rather than pops, so a second rollback returns and the model stays
// one slot deep rather than becoming a history nobody asked for.
func (i *Installer) Rollback(
	ctx context.Context,
	paths Paths,
	set component.Set,
	selected []string,
	current installstate.State,
) (Result, error) {
	sink := i.Sink
	if sink == nil {
		sink = Discard{}
	}

	result := Result{Paths: paths}
	result.Selected = selected
	result.Enabled = state.State{Schema: state.Schema, Selected: selected}.Enabled(set)

	if current.Previous == nil {
		return result, errors.New("there is no previous generation to go back to")
	}
	target := *current.Previous

	tx := NewTransaction(paths)

	fail := func(step string, cause error) (Result, error) {
		sink.Emit(Event{Step: step, Status: StatusFailed, Message: cause.Error()})

		result.RolledBack = true
		if problem := tx.Rollback(); problem != nil {
			result.RollbackProblem = problem
		}
		return result, cause
	}

	// The generation being left becomes the one to come back to, so it is moved
	// aside rather than removed — and it is moved first, because the target
	// path has to be free before the kept generation can take it.
	sink.Emit(Event{Step: "backup", Status: StatusStart})
	if err := tx.BackupTarget(paths); err != nil {
		return fail("backup", err)
	}
	sink.Emit(Event{Step: "backup", Status: StatusDone, Message: tx.Backup})

	sink.Emit(Event{Step: "restore", Status: StatusStart})
	want := Identity{Device: target.Device, Inode: target.Inode, Mtime: target.Mtime}
	if err := tx.RestoreGeneration(target.Path, want, paths); err != nil {
		return fail("restore", err)
	}
	sink.Emit(Event{Step: "restore", Status: StatusDone, Message: target.Path})

	// Both directories have moved and neither is written down yet. Undoing
	// this means moving both back, which is the case `Restored` exists for.
	if err := hit(faultAfterRestore); err != nil {
		return fail("restore", err)
	}

	// Brought to the selection in force, not to the one that generation was
	// installed with. A rollback moves the version; it does not undo a choice.
	if err := tx.Bootstrap(ctx, paths, i.Runner, sink); err != nil {
		return fail("bootstrap", err)
	}

	if err := tx.Verify(ctx, paths, result.Enabled, i.Runner, sink); err != nil {
		return fail("verify", err)
	}
	if err := hit(faultAfterVerify); err != nil {
		return fail("verify", err)
	}

	record := installstate.State{
		Version:       target.Version,
		Contract:      target.Contract,
		AppName:       paths.AppName,
		ConfigDir:     paths.ConfigDir,
		DataDir:       paths.DataDir,
		StateDir:      paths.StateDir,
		CacheDir:      paths.CacheDir,
		SelectionFile: paths.SelectionFile,
		Backup:        tx.Backup,
		Borrowed:      current.Borrowed,
		InstalledAt:   now().Format(time.RFC3339),
		Source:        target.Source,
		Previous: &installstate.Generation{
			Version:     current.Version,
			Contract:    current.Contract,
			Path:        tx.Backup,
			Device:      tx.BackupIdentity.Device,
			Inode:       tx.BackupIdentity.Inode,
			Mtime:       tx.BackupIdentity.Mtime,
			InstalledAt: current.InstalledAt,
			Source:      current.Source,
		},
	}

	sink.Emit(Event{Step: "record", Status: StatusStart})
	written, err := writeRecord(paths.InstallState, record)
	if err != nil && !written.Replaced {
		return fail("record", err)
	}
	if err != nil {
		sink.Emit(Event{Step: "record", Status: StatusWarning, Message: err.Error()})
	}
	result.State = record
	result.Recorded = true

	tx.Commit()
	sink.Emit(Event{Step: "rollback", Status: StatusDone})
	return result, nil
}

// carryOut is the transaction both of them are.
func (i *Installer) carryOut(
	ctx context.Context,
	paths Paths,
	prepared PreparedSource,
	set component.Set,
	selected []string,
	chosenTheme string,
	catalogue theme.Catalogue,
	borrow bool,
	previous *installstate.Generation,
	carriedBorrowed []installstate.Borrowed,
) (Result, error) {
	sink := i.Sink
	if sink == nil {
		sink = Discard{}
	}

	result := Result{Paths: paths}
	result.Selected = selected
	result.Enabled = state.State{Schema: state.Schema, Selected: selected}.Enabled(set)

	tx := NewTransaction(paths)

	// One place where failure is turned into "put it back", so that no step
	// below has to remember to.
	fail := func(step string, cause error) (Result, error) {
		sink.Emit(Event{Step: step, Status: StatusFailed, Message: cause.Error()})

		result.RolledBack = true
		if problem := tx.Rollback(); problem != nil {
			result.RollbackProblem = problem
		}
		return result, cause
	}

	sink.Emit(Event{Step: "selection", Status: StatusStart})
	if err := tx.WriteSelection(selected, set); err != nil {
		return fail("selection", err)
	}

	// Beside the selection and for the same reason it is first: what the editor
	// will come up as is decided before anything is placed, so a failure later
	// is rolled back by one mechanism rather than two.
	if err := tx.WriteTheme(chosenTheme, catalogue); err != nil {
		return fail("theme", err)
	}

	sink.Emit(Event{Step: "stage", Status: StatusStart})
	if err := tx.StageSource(prepared, paths); err != nil {
		return fail("stage", err)
	}

	switch {
	case borrow:
		// Every one of Neovim's directories that exists, not just the
		// configuration: the bootstrap that follows writes plugins, packages
		// and parsers into the other three, and an uninstall that only knew
		// about the first removed the rest as Chroma's own.
		sink.Emit(Event{Step: "backup", Status: StatusStart})
		if err := tx.Borrow(paths); err != nil {
			return fail("backup", err)
		}
		for _, borrowed := range tx.Borrowed {
			sink.Emit(Event{Step: "backup", Status: StatusDone, Message: borrowed.Kind + ": " + borrowed.Backup})
		}
		if err := hit(faultAfterBackup); err != nil {
			return fail("backup", err)
		}

	case previous != nil:
		// Chroma's own tree, moved aside to become the generation to come back
		// to. Nothing is borrowed here, because whatever was borrowed was
		// borrowed by the installation this is replacing, and is carried
		// forward untouched.
		sink.Emit(Event{Step: "backup", Status: StatusStart})
		if err := tx.BackupTarget(paths); err != nil {
			return fail("backup", err)
		}
		sink.Emit(Event{Step: "backup", Status: StatusDone, Message: tx.Backup})
		if err := hit(faultAfterBackup); err != nil {
			return fail("backup", err)
		}
	}

	// The generation only becomes real once its directory has actually moved.
	// Recording a path the backup step never produced would promise a way back
	// to somewhere nothing is.
	if previous != nil {
		previous.Path = tx.Backup
		previous.Device = tx.BackupIdentity.Device
		previous.Inode = tx.BackupIdentity.Inode
		previous.Mtime = tx.BackupIdentity.Mtime
	}

	sink.Emit(Event{Step: "place", Status: StatusStart})
	if err := tx.Place(paths); err != nil {
		return fail("place", err)
	}
	if err := hit(faultAfterPlace); err != nil {
		return fail("place", err)
	}

	if err := tx.Bootstrap(ctx, paths, i.Runner, sink); err != nil {
		return fail("bootstrap", err)
	}
	if err := hit(faultAfterBootstrap); err != nil {
		return fail("bootstrap", err)
	}

	if err := tx.Verify(ctx, paths, result.Enabled, i.Runner, sink); err != nil {
		return fail("verify", err)
	}
	// The boundary the record exists on: the tree is placed, the editor is
	// happy, and nothing has been written down yet.
	if err := hit(faultAfterVerify); err != nil {
		return fail("verify", err)
	}

	// What was borrowed by this run, or what an earlier run borrowed and this
	// one is only carrying. Never both: the switch above takes one branch.
	borrowed := carriedBorrowed
	if borrow {
		borrowed = tx.Borrowed
	}

	record := installstate.State{
		Version:       prepared.Version,
		Contract:      prepared.Contract,
		AppName:       paths.AppName,
		ConfigDir:     paths.ConfigDir,
		DataDir:       paths.DataDir,
		StateDir:      paths.StateDir,
		CacheDir:      paths.CacheDir,
		SelectionFile: paths.SelectionFile,
		Backup:        tx.Backup,
		Borrowed:      borrowed,
		Previous:      previous,
		InstalledAt:   now().Format(time.RFC3339),
		Source:        sourceOf(prepared),
	}

	sink.Emit(Event{Step: "record", Status: StatusStart})
	written, err := writeRecord(paths.InstallState, record)
	if err != nil && !written.Replaced {
		// Rolled back rather than left alone: an unmanaged directory is one every
		// command knows how to refuse, but it is one the user did not have before.
		return fail("record", err)
	}
	if err != nil {
		// The record is already the new one, and rolling the tree back would put
		// the two on opposite sides of the same boundary. The commit stands and
		// the problem is reported.
		sink.Emit(Event{Step: "record", Status: StatusWarning, Message: err.Error()})
	}
	result.State = record
	result.Recorded = true

	tx.Commit()
	if err := tx.Cleanup(); err != nil {
		// Not a failure of the installation: the configuration is placed,
		// verified and recorded. A staging directory nobody removed is untidy,
		// and saying so is better than pretending it is not there.
		sink.Emit(Event{Step: "cleanup", Status: StatusWarning, Message: err.Error()})
	}

	sink.Emit(Event{Step: "install", Status: StatusDone})
	return result, nil
}

// sourceOf describes where this installation came from, in the terms update and
// rollback read it in. From the prepared source rather than the request: what
// was asked for and what arrived are two different facts.
func sourceOf(prepared PreparedSource) installstate.Source {
	if prepared.Kind == KindTree {
		return installstate.Source{Type: installstate.FromTree, Ref: prepared.Root}
	}
	return installstate.Source{Type: installstate.FromRelease, Ref: prepared.Version, SHA256: prepared.SHA256}
}

// Describe renders the result for somebody reading a terminal.
func (r Result) Describe() string {
	if r.Recorded {
		return fmt.Sprintf("Chroma Neovim is installed at %s.", r.Paths.ConfigDir)
	}

	switch {
	case r.RollbackProblem != nil:
		return fmt.Sprintf("The installation failed and putting things back did not entirely work: %v", r.RollbackProblem)
	case r.RolledBack:
		return "The installation failed. The previous configuration and selection were put back, and nothing was recorded."
	default:
		return "The installation did not start, and nothing was changed."
	}
}

// handoverFor keeps the record's two halves in step: a path to hold means the
// configuration is held, and no path means there is nothing to give back.
func handoverFor(userBackup string, carried installstate.Handover) installstate.Handover {
	if userBackup == "" {
		if carried == installstate.HandoverHandedBack {
			return carried
		}
		return installstate.HandoverNone
	}
	if carried == installstate.HandoverPending {
		return carried
	}
	return installstate.HandoverHeld
}
