package main

import (
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// world is every file under a root and what is in it, plus the identity of every
// directory, so that "nothing was touched" is a comparison and not a hope.
func world(t *testing.T, root string) map[string]string {
	t.Helper()

	found := map[string]string{}
	_ = filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		relative, relErr := filepath.Rel(root, path)
		if relErr != nil {
			return nil
		}
		if entry.IsDir() {
			if identity, idErr := install.Identify(path); idErr == nil {
				found[relative+"/"] = fmt.Sprintf("%+v", identity)
			}
			return nil
		}
		if contents, readErr := os.ReadFile(path); readErr == nil {
			digest := sha256.Sum256(contents)
			found[relative] = hex.EncodeToString(digest[:])
		}
		return nil
	})
	return found
}

func differences(before, after map[string]string) []string {
	var problems []string
	for name, was := range before {
		switch now, still := after[name]; {
		case !still:
			problems = append(problems, "gone:    "+name)
		case now != was:
			problems = append(problems, "changed: "+name)
		}
	}
	for name := range after {
		if _, was := before[name]; !was {
			problems = append(problems, "created: "+name)
		}
	}
	sort.Strings(problems)
	return problems
}

func under(paths install.Paths) string {
	return filepath.Dir(filepath.Dir(paths.ConfigDir))
}

// interrupted arranges the one topology recovery will act on: the record points
// at a generation that is not there, and exactly one unreferenced Chroma backup
// stands beside the target.
func interrupted(t *testing.T, paths install.Paths) {
	t.Helper()

	orphan := paths.ConfigDir + ".chroma-backup-20260810T000000Z"
	if err := os.MkdirAll(filepath.Join(orphan, "lua", "chroma"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"init.lua", filepath.Join("lua", "chroma", "bootstrap.lua")} {
		if err := os.WriteFile(filepath.Join(orphan, name), []byte("-- interrupted\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	record.Previous = &installstate.Generation{
		Version: "v0.9.0",
		Path:    paths.ConfigDir + ".chroma-backup-20260809T000000Z",
		Source:  installstate.Source{Type: installstate.FromRelease, Ref: "v0.9.0"},
	}
	if _, err := installstate.Write(paths.InstallState, record); err != nil {
		t.Fatal(err)
	}
}

// **Point 9.** One managed installation per user, refused in both directions.
//
// Measured before this refusal existed: a second install reported success, and
// afterwards update, components, rollback and uninstall all answered "Two Chroma
// installations are recorded and this cannot tell which you mean" — with no flag
// in the product to say which. A state the CLI made and could not get out of.
func TestASecondInstallationIsRefused(t *testing.T) {
	for _, tc := range []struct {
		name     string
		existing bool
		args     []string
	}{
		{"an isolated one exists, a takeover is asked for", false, []string{"--default"}},
		{"a takeover exists, an isolated one is asked for", true, nil},
	} {
		t.Run(tc.name, func(t *testing.T) {
			isolated, takeover := blank(t)

			here, there := isolated, takeover
			if tc.existing {
				here, there = takeover, isolated
			}
			recordAt(t, here)

			root := under(isolated)
			before := world(t, root)

			args := append(append([]string{}, tc.args...),
				"--source-tree", bare(t), "--components", "", "--non-interactive", "--yes")
			printed, code := say(t, func(out, errOut *os.File) int { return cmdInstall(args, out, errOut) })

			if code != exitMisuse {
				t.Errorf("a second installation exited %d, want %d:\n%s", code, exitMisuse, printed)
			}
			if !strings.Contains(printed, "already installed") {
				t.Errorf("the refusal does not say what is wrong:\n%s", printed)
			}
			if changed := differences(before, world(t, root)); len(changed) > 0 {
				t.Errorf("the refused install changed the machine:\n  %s", strings.Join(changed, "\n  "))
			}
			if _, err := os.Stat(there.InstallState); err == nil {
				t.Errorf("%s was installed anyway", there.ConfigDir)
			}
		})
	}
}

// recordAt puts a recorded installation at one of the two shapes.
func recordAt(t *testing.T, paths install.Paths) {
	t.Helper()

	for _, dir := range []string{paths.ConfigDir, paths.StateDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	record := installstate.State{
		Schema: installstate.Schema, Version: "v1.0.0", Contract: 5, AppName: paths.AppName,
		ConfigDir: paths.ConfigDir, DataDir: paths.DataDir, StateDir: paths.StateDir,
		CacheDir: paths.CacheDir, SelectionFile: paths.SelectionFile,
		InstalledAt: "2026-08-10T00:00:00Z",
		Source:      installstate.Source{Type: installstate.FromRelease, Ref: "v1.0.0"},
	}
	if _, err := installstate.Write(paths.InstallState, record); err != nil {
		t.Fatal(err)
	}
}

// **Point 12.** A dry run changes nothing at all — not the topology, not the
// record, and not the lock file.
//
// Measured before this: `chroma update --dry-run` on an interrupted topology
// took the lock, ran recovery, moved two directories and reported an interrupted
// rollback as something it had already put back. `--dry-run` has to mean "no
// change to this machine", not "skip the main operation".
func TestADryRunOnAnInterruptedTopologyChangesNothing(t *testing.T) {
	for _, tc := range []struct {
		name  string
		setUp func(*testing.T, install.Paths)
		run   func([]string, *os.File, *os.File) int
	}{
		{"update", func(t *testing.T, paths install.Paths) { chose(t, paths); offline(t) }, cmdUpdate},
		{"rollback", func(t *testing.T, paths install.Paths) { chose(t, paths) }, cmdRollback},
		{"uninstall", func(t *testing.T, paths install.Paths) {}, cmdUninstall},
	} {
		t.Run(tc.name, func(t *testing.T) {
			paths := machine(t)
			tc.setUp(t, paths)
			interrupted(t, paths)

			root := under(paths)
			before := world(t, root)

			printed, _ := say(t, func(out, errOut *os.File) int { return tc.run([]string{"--dry-run"}, out, errOut) })

			if changed := differences(before, world(t, root)); len(changed) > 0 {
				t.Errorf("%s --dry-run changed the machine:\n  %s\n--- said ---\n%s",
					tc.name, strings.Join(changed, "\n  "), printed)
			}
			if !strings.Contains(printed, "did not finish") {
				t.Errorf("%s --dry-run did not say that a real run would have to recover first:\n%s", tc.name, printed)
			}
		})
	}
}

// The other half, and the one that stops the fix from being "never recover":
// the real command still does.
func TestARealRunStillRecovers(t *testing.T) {
	paths := machine(t)
	chose(t, paths)
	interrupted(t, paths)

	orphan := paths.ConfigDir + ".chroma-backup-20260810T000000Z"
	recorded := paths.ConfigDir + ".chroma-backup-20260809T000000Z"

	printed, _ := say(t, func(out, errOut *os.File) int {
		return cmdRollback([]string{"--yes"}, out, errOut)
	})

	// The repair itself, named rather than inferred from "something changed":
	// the unreferenced backup is put where the record says the generation is,
	// so the two agree again.
	if _, err := os.Stat(orphan); err == nil {
		t.Errorf("the interrupted transaction's backup is still at %s:\n%s", orphan, printed)
	}
	if _, err := os.Stat(recorded); err != nil {
		t.Errorf("the recorded generation is still missing from %s: %v\n%s", recorded, err, printed)
	}
	if !strings.Contains(printed, "did not finish") {
		t.Errorf("the run did not say it had found an interrupted transaction:\n%s", printed)
	}
}

// And install: its dry run was already clean once the lock moved after the
// plan, which is worth holding in place rather than assuming.
func TestAnInstallDryRunLeavesNoFootprint(t *testing.T) {
	isolated, _ := blank(t)
	root := under(isolated)
	before := world(t, root)

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdInstall([]string{"--source-tree", bare(t), "--components", "", "--non-interactive", "--dry-run"}, out, errOut)
	})
	if code != exitOK {
		t.Fatalf("exit %d:\n%s", code, printed)
	}
	if changed := differences(before, world(t, root)); len(changed) > 0 {
		t.Errorf("install --dry-run changed the machine:\n  %s", strings.Join(changed, "\n  "))
	}
}
