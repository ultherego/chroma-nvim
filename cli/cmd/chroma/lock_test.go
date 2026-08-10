package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/lock"
)

// machine gives a test its own XDG tree with one recorded installation in it.
func machine(t *testing.T) install.Paths {
	t.Helper()

	root := t.TempDir()
	for _, pair := range [][2]string{
		{"XDG_CONFIG_HOME", "config"},
		{"XDG_DATA_HOME", "data"},
		{"XDG_STATE_HOME", "state"},
		{"XDG_CACHE_HOME", "cache"},
	} {
		t.Setenv(pair[0], filepath.Join(root, pair[1]))
	}

	paths, err := install.ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	// Enough of an installation for `managed` to find it. The commands under
	// test all stop at the lock, before any of this is read for content.
	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(paths.StateDir, 0o755); err != nil {
		t.Fatal(err)
	}

	record := installstate.State{
		Schema:        installstate.Schema,
		Version:       "v1.0.0",
		Contract:      5,
		AppName:       paths.AppName,
		ConfigDir:     paths.ConfigDir,
		DataDir:       paths.DataDir,
		StateDir:      paths.StateDir,
		CacheDir:      paths.CacheDir,
		SelectionFile: paths.SelectionFile,
		InstalledAt:   "2026-08-10T00:00:00Z",
		Source:        installstate.Source{Type: installstate.FromRelease, Ref: "v1.0.0"},
	}
	encoded, err := json.Marshal(record)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.InstallState, encoded, 0o644); err != nil {
		t.Fatal(err)
	}

	return paths
}

// captured runs a command with its error output collected.
func captured(t *testing.T, run func(errOut *os.File) int) (int, string) {
	t.Helper()

	file, err := os.CreateTemp(t.TempDir(), "err")
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	code := run(file)

	contents, err := os.ReadFile(file.Name())
	if err != nil {
		t.Fatal(err)
	}
	return code, string(contents)
}

// A lock nobody takes is the same class of bug as a command nobody can reach:
// the mechanism is there, it is correct, and it protects nothing. Every command
// that moves a directory or rewrites the record has to be held off by it.
func TestEveryMutatingCommandTakesTheLock(t *testing.T) {
	for _, tc := range []struct {
		name string
		args []string
		run  func(args []string, out, errOut *os.File) int
	}{
		// install locks after it has a tree to install and before it looks at
		// the target, so a source tree is needed to reach the lock at all.
		{"install", []string{"--source-tree", filepath.Join("..", "..", ".."), "--components", "", "--dry-run"}, cmdInstall},
		{"update", []string{"--dry-run"}, cmdUpdate},
		{"components", []string{"--set", "terraform", "--yes"}, cmdComponents},
		{"rollback", []string{"--dry-run"}, cmdRollback},
		{"uninstall", []string{"--dry-run"}, cmdUninstall},
	} {
		t.Run(tc.name, func(t *testing.T) {
			paths := machine(t)

			held, err := lock.Acquire(filepath.Join(paths.StateDir, "lock"))
			if err != nil {
				t.Fatalf("Acquire: %v", err)
			}
			defer held.Release()

			code, errOut := captured(t, func(errFile *os.File) int {
				return tc.run(tc.args, os.Stdout, errFile)
			})

			if code == exitOK {
				t.Errorf("%s ran while another operation held the lock", tc.name)
			}
			if !strings.Contains(errOut, "already in progress") {
				t.Errorf("%s did not say why it stopped: %q", tc.name, errOut)
			}
		})
	}
}

// And the reading command is not held off, because it changes nothing.
func TestDoctorDoesNotTakeTheLock(t *testing.T) {
	paths := machine(t)

	held, err := lock.Acquire(filepath.Join(paths.StateDir, "lock"))
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer held.Release()

	_, errOut := captured(t, func(errFile *os.File) int {
		return cmdDoctor([]string{"--tree", filepath.Join("..", "..", "..", "components")}, os.Stdout, errFile)
	})

	if strings.Contains(errOut, "already in progress") {
		t.Error("doctor waited for a lock it does not need; it only reads")
	}
}

// A run killed between giving the user's configuration back and recording that
// leaves a record which disagrees with the disk. The plan is printed before
// anybody agrees to it, so it has to be built from the reconciled record —
// otherwise `uninstall` offers to remove the configuration it has just handed
// over, which is the one thing this command must never say.
func TestTheUninstallPlanDoesNotOfferAHandedBackConfiguration(t *testing.T) {
	paths := machine(t)

	// The state that window leaves: the backup consumed by the rename, the
	// record still naming it, and the directory holding somebody else's work.
	userBackup := paths.ConfigDir + ".their-own-config"
	if err := os.WriteFile(filepath.Join(paths.ConfigDir, "init.lua"), []byte("-- mine\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	record, _, err := installstate.Load(paths.InstallState)
	if err != nil {
		t.Fatal(err)
	}
	record.UserBackup = userBackup
	if err := installstate.Write(paths.InstallState, record); err != nil {
		t.Fatal(err)
	}

	printed, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer printed.Close()

	if code := cmdUninstall([]string{"--dry-run"}, printed, os.Stderr); code != exitOK {
		t.Fatalf("the dry run exited %d", code)
	}

	contents, err := os.ReadFile(printed.Name())
	if err != nil {
		t.Fatal(err)
	}
	plan := string(contents)

	remove, _, _ := strings.Cut(plan, "External tools will not be removed")
	if strings.Contains(remove, paths.ConfigDir+"\n") {
		t.Errorf("the plan offers to remove the configuration already handed back:\n%s", plan)
	}
	if !strings.Contains(plan, "already been given back") {
		t.Errorf("the plan does not say what it worked out:\n%s", plan)
	}
}
