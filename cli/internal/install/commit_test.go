package install

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/atomicfile"
	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// stopAfterRename makes the next atomic replacement fail after it has already
// happened — the window between the rename and the directory flush.
func stopAfterRename(t *testing.T, forFile string) error {
	t.Helper()

	stopped := errors.New("the directory could not be flushed")

	switch forFile {
	case "install.json":
		real := writeRecord
		writeRecord = func(path string, record installstate.State) (atomicfile.Result, error) {
			result, err := real(path, record)
			if err != nil {
				return result, err
			}
			// Replaced, and not confirmed durable: the rename committed and the
			// caller is about to be told the write failed.
			return atomicfile.Result{Replaced: true}, stopped
		}
		t.Cleanup(func() { writeRecord = real })

	case "components.json":
		real := writeSelection
		writeSelection = func(path string, chosen state.State, set component.Set) (atomicfile.Result, error) {
			result, err := real(path, chosen, set)
			if err != nil {
				return result, err
			}
			return atomicfile.Result{Replaced: true}, stopped
		}
		t.Cleanup(func() { writeSelection = real })

	default:
		t.Fatalf("no seam for %s", forFile)
	}

	return stopped
}

// A record write that fails after its rename has committed. The tree and the
// record have to end up on the same side of that boundary — which they did not
// before this was measured: the write was reported as not having happened, the
// transaction rolled the tree back to v1, and the record described v2.
//
// Rolling back from there undoes something that was never done and leaves in
// place something that was. So the commit stands, and what is reported is the
// durability, not the contents.
func TestARecordWriteThatCommittedIsNotRolledBack(t *testing.T) {
	fixed(t)

	paths, current := installed(t, []string{"terraform"})
	mark(t, paths.ConfigDir, "v1")
	current.Version = "v1.0.0"
	current.Source = installstate.Source{Type: installstate.FromRelease, Ref: "v1.0.0", SHA256: "a"}
	if _, err := installstate.Write(paths.InstallState, current); err != nil {
		t.Fatal(err)
	}

	source := prepared(t)
	mark(t, source.Root, "v2")

	stopAfterRename(t, "install.json")

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Update(context.Background(), paths, source, shipped(t), []string{"terraform"}, current)
	if err != nil {
		t.Fatalf("the update was rolled back although its record had already committed: %v", err)
	}
	if result.RolledBack {
		t.Error("the transaction rolled back past a commit that had happened")
	}

	onDisk := held(t, paths.ConfigDir)
	record, found, loadErr := installstate.Load(paths.InstallState)
	if loadErr != nil || !found {
		t.Fatalf("Load: %v found=%v", loadErr, found)
	}

	if onDisk != "v2" {
		t.Errorf("the tree holds %q, want the generation the record now describes", onDisk)
	}
	if record.Previous == nil || record.Previous.Version != "v1.0.0" {
		t.Errorf("the record does not describe the update it committed: %+v", record.Previous)
	}
}

// The same primitive under components: the selection may be replaced and the
// transaction told it was not, so the rollback leaves the new one in force.
func TestAFailedSelectionWriteThatAlreadyHappenedStaysInForce(t *testing.T) {
	fixed(t)

	paths, _ := installed(t, []string{"terraform"})
	before, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatal(err)
	}

	stopAfterRename(t, "components.json")

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Reconfigure(context.Background(), paths, shipped(t), []string{"kubernetes"}); err == nil {
		t.Fatal("the change reported success")
	}

	after, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Errorf("the failed change is the one in force:\nbefore %s\nafter  %s", before, after)
	}
	if strings.Contains(string(after), "kubernetes") {
		t.Error("the selection that was reported as not written is the one on disk")
	}
}

// The same rule, at the other place it is written down. `Rollback` has its own
// record write and its own decision about whether a failed one undoes the move,
// and the test above never reached it — a mutant that made rollback undo a
// commit it had already made survived the entire suite.
//
// It matters more here than in an update: what would be rolled back is a
// generation that was moved, not a tree that was placed, so getting it wrong
// means the version on disk and the version in the record disagree about which
// way round the two generations are.
func TestARollbackWhoseRecordCommittedKeepsTheGenerationItRestored(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	mark(t, paths.ConfigDir, "v2")
	mark(t, current.Previous.Path, "v1")

	stopAfterRename(t, "install.json")

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current)
	if err != nil {
		t.Fatalf("the rollback was undone although its record had already committed: %v", err)
	}
	if result.RolledBack {
		t.Error("the transaction rolled back past a commit that had happened")
	}

	if onDisk := held(t, paths.ConfigDir); onDisk != "v1" {
		t.Errorf("the tree holds %q, want the generation the record now describes", onDisk)
	}

	record, found, loadErr := installstate.Load(paths.InstallState)
	if loadErr != nil || !found {
		t.Fatalf("Load: %v found=%v", loadErr, found)
	}
	if record.Previous == nil {
		t.Fatal("the record kept no way back after the swap")
	}
	if got := held(t, record.Previous.Path); got != "v2" {
		t.Errorf("the recorded previous generation holds %q, want v2", got)
	}
}
