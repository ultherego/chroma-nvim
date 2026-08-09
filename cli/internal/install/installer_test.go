package install

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// failAt is a Runner that lets the installation get to one step and then does
// not come back from it. The steps it can fail are the ones that run a Neovim.
type failAt struct {
	step string
	runs int
}

func (f *failAt) Run(_ context.Context, cmd Command, _ ProgressSink) error {
	f.runs++
	joined := strings.Join(cmd.Args, " ")
	if strings.Contains(joined, `run("`+f.step+`"`) {
		return errors.New("the editor said no")
	}
	return nil
}

func applied(t *testing.T, runner Runner, opts Options) (Result, error, Paths) {
	t.Helper()

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	source := prepared(t)
	installer := &Installer{Runner: runner}
	result, err := installer.Apply(context.Background(), opts, paths, source, shipped(t))
	return result, err, paths
}

func TestAVerifiedInstallationIsRecorded(t *testing.T) {
	fixed(t)

	result, err, paths := applied(t, &failAt{}, Options{Selected: []string{"terraform"}})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("nothing was placed")
	}
	if !result.Recorded {
		t.Fatal("a verified installation was not recorded")
	}

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	if record.ConfigDir != paths.ConfigDir || record.AppName != AppName {
		t.Errorf("recorded %+v", record)
	}
	// A tree installation has no version, and that is the fact update needs.
	if record.Source.Type != installstate.FromTree || record.Version != "" {
		t.Errorf("source = %+v, version = %q", record.Source, record.Version)
	}

	written, err := os.ReadFile(paths.SelectionFile)
	if err != nil {
		t.Fatalf("reading the selection: %v", err)
	}
	if !strings.Contains(string(written), "terraform") {
		t.Errorf("selection = %s", written)
	}

	// Nothing left beside the installation.
	entries, err := os.ReadDir(paths.BackupDir)
	if err != nil {
		t.Fatalf("reading %s: %v", paths.BackupDir, err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), "chroma-stage") {
			t.Errorf("a staging directory survived: %s", entry.Name())
		}
	}
}

// The whole reason the order is the order: whatever fails, the machine goes
// back to what it was, and nothing is recorded.
func TestAFailureAtAnyStepLeavesTheMachineAsItWas(t *testing.T) {
	for _, step := range []string{"install", "verify"} {
		t.Run("failing at "+step, func(t *testing.T) {
			fixed(t)

			result, err, paths := applied(t, &failAt{step: step}, Options{Selected: []string{"terraform"}})
			if err == nil {
				t.Fatalf("a failed %s was reported as success", step)
			}

			if result.Recorded {
				t.Error("an installation that failed was recorded")
			}
			if _, statErr := os.Stat(paths.InstallState); !os.IsNotExist(statErr) {
				t.Error("install.json exists after a failed installation")
			}
			if exists(paths.ConfigDir) {
				t.Error("the placed configuration was left behind")
			}
			if _, statErr := os.Stat(paths.SelectionFile); !os.IsNotExist(statErr) {
				t.Error("the selection this install wrote was left behind")
			}
			if !result.RolledBack || result.RollbackProblem != nil {
				t.Errorf("rollback = %v, problem = %v", result.RolledBack, result.RollbackProblem)
			}
		})
	}
}

// Taking over an existing configuration is the case with something to lose.
func TestAFailedTakeoverPutsTheOldConfigurationBack(t *testing.T) {
	fixed(t)
	xdg(t, t.TempDir())

	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the existing configuration: %v", err)
	}
	write(t, filepath.Join(paths.ConfigDir, "init.lua"), "-- what was here before\n")

	installer := &Installer{Runner: &failAt{step: "verify"}}
	result, err := installer.Apply(
		context.Background(),
		Options{UseDefault: true, Selected: []string{"vault"}},
		paths,
		prepared(t),
		shipped(t),
	)
	if err == nil {
		t.Fatal("a failed verify was reported as success")
	}
	if result.RollbackProblem != nil {
		t.Fatalf("rollback did not work: %v", result.RollbackProblem)
	}

	got := readFile(t, filepath.Join(paths.ConfigDir, "init.lua"))
	if !strings.Contains(got, "what was here before") {
		t.Errorf("the previous configuration did not come back: %q", got)
	}
}

// The refusals happen before anything is written, which is the only point at
// which refusing is free.
func TestNothingHappensWhenTheRequestCannotBeSatisfied(t *testing.T) {
	for _, tc := range []struct {
		name    string
		options Options
		mention string
	}{
		{"a component that does not exist", Options{Selected: []string{"magic"}}, "no component magic"},
		{"core named explicitly", Options{Selected: []string{"core"}}, `"core"`},
		{"a profile and a list", Options{Profile: "minimal", Selected: []string{"aws"}}, "use one"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			result, err, paths := applied(t, &failAt{}, tc.options)
			if err == nil {
				t.Fatal("a request that cannot be satisfied was carried out")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to mention %q", err, tc.mention)
			}
			if result.RolledBack {
				t.Error("rolled back an installation that never started")
			}
			if exists(paths.ConfigDir) || exists(paths.SelectionFile) {
				t.Error("something was written before the request was checked")
			}
		})
	}
}

// An existing managed installation is an update, and replacing it while its
// state still describes the old one is how a record starts lying.
func TestAnExistingInstallationIsNotReinstalledOver(t *testing.T) {
	fixed(t)

	_, err, paths := applied(t, &failAt{}, Options{Selected: []string{"terraform"}})
	if err != nil {
		t.Fatalf("first Apply: %v", err)
	}

	installer := &Installer{Runner: &failAt{}}
	_, err = installer.Apply(
		context.Background(),
		Options{Selected: []string{"vault"}},
		paths,
		prepared(t),
		shipped(t),
	)
	if err == nil || !strings.Contains(err.Error(), "chroma update") {
		t.Errorf("err = %v, want it to point at update", err)
	}

	// And the first installation is untouched.
	record, found, loadErr := installstate.Load(paths.InstallState)
	if loadErr != nil || !found {
		t.Fatalf("Load: %v found=%v", loadErr, found)
	}
	if !strings.Contains(readFile(t, paths.SelectionFile), "terraform") {
		t.Error("the first installation's selection was replaced")
	}
	_ = record
}

// Verify is told what was selected, resolved through the graph — not the flag
// list. Terraform requires core, and an installation without core running is
// not the one that was asked for whatever the flag said.
func TestVerifyIsToldTheResolvedComponents(t *testing.T) {
	fixed(t)

	recorded := &recorder{}
	result, err, _ := applied(t, recorded, Options{Selected: []string{"terraform"}})
	if err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if strings.Join(result.Enabled, ",") != "core,terraform" {
		t.Errorf("enabled = %v, want core pulled in", result.Enabled)
	}

	var verify string
	for _, cmd := range recorded.commands {
		joined := strings.Join(cmd.Args, " ")
		if strings.Contains(joined, `run("verify"`) {
			verify = joined
		}
	}
	if !strings.Contains(verify, `{ "core", "terraform" }`) {
		t.Errorf("verify was told %q", verify)
	}
}
