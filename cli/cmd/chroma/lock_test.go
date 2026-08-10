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

	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))
	if err := os.MkdirAll(filepath.Join(root, "run"), 0o755); err != nil {
		t.Fatal(err)
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
		// install takes the lock after the plan and the confirmation, because
		// until the interactive flow has answered it does not know which
		// installation it would touch. So this drives it past both.
		{"install", []string{"--source-tree", filepath.Join("..", "..", ".."), "--components", "", "--yes"}, cmdInstall},
		{"update", []string{"--dry-run"}, cmdUpdate},
		{"components", []string{"--set", "terraform", "--yes"}, cmdComponents},
		{"rollback", []string{"--dry-run"}, cmdRollback},
		{"uninstall", []string{"--dry-run"}, cmdUninstall},
	} {
		t.Run(tc.name, func(t *testing.T) {
			machine(t)

			lockPath, err := lock.Path()
			if err != nil {
				t.Fatal(err)
			}
			held, err := lock.Acquire(lockPath)
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
	machine(t)

	lockPath, err := lock.Path()
	if err != nil {
		t.Fatal(err)
	}
	held, err := lock.Acquire(lockPath)
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
	// The state a kill inside the transfer leaves: the intention recorded, the
	// rename done, the completion not written.
	record.UserBackup = userBackup
	record.Handover = installstate.HandoverPending
	if _, err := installstate.Write(paths.InstallState, record); err != nil {
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

// blank gives a test an empty machine: XDG dirs of its own, no installation.
func blank(t *testing.T) (isolated install.Paths, takeover install.Paths) {
	t.Helper()

	root := t.TempDir()
	for _, pair := range [][2]string{
		{"XDG_CONFIG_HOME", "config"}, {"XDG_DATA_HOME", "data"},
		{"XDG_STATE_HOME", "state"}, {"XDG_CACHE_HOME", "cache"},
	} {
		t.Setenv(pair[0], filepath.Join(root, pair[1]))
	}

	isolated, err := install.ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}
	takeover, err = install.ResolvePaths(true)
	if err != nil {
		t.Fatal(err)
	}
	return isolated, takeover
}

// answering points os.Stdin at a script of replies.
func answering(t *testing.T, lines ...string) {
	t.Helper()

	file, err := os.CreateTemp(t.TempDir(), "stdin")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(strings.Join(lines, "\n") + "\n"); err != nil {
		t.Fatal(err)
	}
	if _, err := file.Seek(0, 0); err != nil {
		t.Fatal(err)
	}

	saved := os.Stdin
	os.Stdin = file
	t.Cleanup(func() { os.Stdin = saved; file.Close() })
}

// Audit finding 4A: the lock is taken before the question that decides which
// installation is about to be changed.
//
// `install` locks the isolated placement, then the interactive flow may answer
// "take over ~/.config/nvim". The paths are recomputed; the lock is not. So a
// takeover proceeds while another process holds the lock for exactly that
// installation.
func TestInstallLocksTheInstallationItWillActuallyTouch(t *testing.T) {
	blank(t)
	t.Setenv("XDG_RUNTIME_DIR", t.TempDir())

	// Another process is already mutating a Chroma installation.
	path, err := lock.Path()
	if err != nil {
		t.Fatal(err)
	}
	held, err := lock.Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer held.Release()

	// 2 = take over ~/.config/nvim, then accept an empty component selection.
	answering(t, "2", "")

	code, errOut := captured(t, func(errFile *os.File) int {
		return cmdInstall([]string{
			"--source-tree", filepath.Join("..", "..", ".."),
			"--yes",
		}, os.Stdout, errFile)
	})

	if !strings.Contains(errOut, "already in progress") {
		t.Errorf("install went ahead with a takeover while that installation was locked (exit %d):\n%s", code, errOut)
	}
}

// The lock is taken after the plan and the confirmation, which is what makes a
// dry run leave nothing at all. Taking it earlier was how `install --dry-run`
// created a lock file on a machine it had been asked not to touch.
func TestADryRunLeavesNoLockBehind(t *testing.T) {
	blank(t)
	runtime := t.TempDir()
	t.Setenv("XDG_RUNTIME_DIR", runtime)

	answering(t, "1", "")

	captured(t, func(errFile *os.File) int {
		return cmdInstall([]string{
			"--source-tree", filepath.Join("..", "..", ".."),
			"--dry-run",
		}, os.Stdout, errFile)
	})

	entries, err := os.ReadDir(runtime)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		t.Errorf("a dry run left %s behind", entry.Name())
	}
}
