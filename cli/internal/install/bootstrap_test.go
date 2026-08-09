package install

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
	"time"
)

// recorder is a Runner that remembers instead of running.
type recorder struct {
	commands []Command
	fail     error
	deadline bool
}

func (r *recorder) Run(ctx context.Context, cmd Command, _ ProgressSink) error {
	_, r.deadline = ctx.Deadline()
	r.commands = append(r.commands, cmd)
	return r.fail
}

func placed(t *testing.T) (*Transaction, Paths) {
	t.Helper()

	tx, paths := target(t)
	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}
	return tx, paths
}

func TestBootstrapDrivesTheEntrypointInTheInstalledTree(t *testing.T) {
	tx, paths := placed(t)
	runner := &recorder{}

	if err := tx.Bootstrap(context.Background(), paths, runner, nil); err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}

	if len(runner.commands) != 1 {
		t.Fatalf("ran %d commands, want one", len(runner.commands))
	}
	cmd := runner.commands[0]

	if !strings.HasSuffix(cmd.Name, "nvim") {
		t.Errorf("ran %q, want nvim", cmd.Name)
	}
	joined := strings.Join(cmd.Args, " ")
	if !strings.Contains(joined, "--headless") {
		t.Errorf("args = %v, want a headless Neovim", cmd.Args)
	}
	if !strings.Contains(joined, `require("chroma.bootstrap").run("install")`) {
		t.Errorf("args = %v, want the bootstrap entrypoint", cmd.Args)
	}

	// The isolated installation is only reachable through NVIM_APPNAME.
	if !containsEnv(cmd.Env, "NVIM_APPNAME="+AppName) {
		t.Errorf("env = %v, want NVIM_APPNAME=%s", cmd.Env, AppName)
	}
}

// Neovim finds its own directory. Setting NVIM_APPNAME=nvim would describe the
// default installation as something it is not.
func TestTheDefaultInstallationGetsNoAppName(t *testing.T) {
	xdg(t, t.TempDir())
	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	tx := NewTransaction(paths)
	if err := tx.StageSource(prepared(t), paths); err != nil {
		t.Fatalf("StageSource: %v", err)
	}
	if err := tx.Place(paths); err != nil {
		t.Fatalf("Place: %v", err)
	}

	runner := &recorder{}
	if err := tx.Bootstrap(context.Background(), paths, runner, nil); err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}

	for _, entry := range runner.commands[0].Env {
		if strings.HasPrefix(entry, "NVIM_APPNAME=") {
			t.Errorf("the default installation was given %q", entry)
		}
	}
}

// Every subprocess is bounded, and "every" cannot depend on the caller
// remembering to bound it.
func TestAnUnboundedContextIsGivenADeadline(t *testing.T) {
	tx, paths := placed(t)
	runner := &recorder{}

	if err := tx.Bootstrap(context.Background(), paths, runner, nil); err != nil {
		t.Fatalf("Bootstrap: %v", err)
	}
	if !runner.deadline {
		t.Error("the child was run with no deadline at all")
	}
}

func TestVerifyPassesTheSelectedComponents(t *testing.T) {
	tx, paths := placed(t)
	runner := &recorder{}

	if err := tx.Verify(context.Background(), paths, []string{"core", "terraform"}, runner, nil); err != nil {
		t.Fatalf("Verify: %v", err)
	}

	joined := strings.Join(runner.commands[0].Args, " ")
	if !strings.Contains(joined, `run("verify", { "core", "terraform" })`) {
		t.Errorf("args = %v, want verify to be told what was selected", runner.commands[0].Args)
	}
}

// A failed bootstrap is a failed installation, not a success with a warning.
func TestAFailedStepIsAnError(t *testing.T) {
	tx, paths := placed(t)
	runner := &recorder{fail: errors.New("these parsers did not install: hcl")}

	err := tx.Bootstrap(context.Background(), paths, runner, nil)
	if err == nil {
		t.Fatal("a failed bootstrap was reported as success")
	}
	if !strings.Contains(err.Error(), "hcl") {
		t.Errorf("err = %v, want it to carry what the editor said", err)
	}
}

func TestNothingIsBootstrappedBeforeItIsPlaced(t *testing.T) {
	tx, paths := target(t)

	if err := tx.Bootstrap(context.Background(), paths, &recorder{}, nil); err == nil {
		t.Error("bootstrapped a configuration that was never placed")
	}
	if err := tx.Verify(context.Background(), paths, nil, &recorder{}, nil); err == nil {
		t.Error("verified a configuration that was never placed")
	}
}

// ---------------------------------------------------------------------------
// The runner itself

func TestExecRunnerStreamsAndReportsFailure(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh; this project is Unix-first and says so")
	}

	var seen []string
	sink := sinkFunc(func(e Event) {
		if e.Status == StatusProgress {
			seen = append(seen, e.Message)
		}
	})

	runner := ExecRunner{}
	err := runner.Run(context.Background(), Command{
		Name: "/bin/sh",
		Args: []string{"-c", "echo first; echo second 1>&2; exit 3"},
	}, sink)

	if err == nil {
		t.Fatal("a command that exited 3 was reported as success")
	}
	// Both streams, because the detail a user needs is as likely to be on one
	// as the other.
	if strings.Join(seen, " ") != "first second" {
		t.Errorf("saw %v, want both streams in order", seen)
	}
	if !strings.Contains(err.Error(), "second") {
		t.Errorf("err = %v, want the last lines in it", err)
	}
}

// A cancelled context kills the child, which is what makes a hung bootstrap a
// failed installation rather than a terminal nobody can get back.
func TestExecRunnerStopsAChildThatWillNotFinish(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh; this project is Unix-first and says so")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	started := time.Now()
	err := ExecRunner{}.Run(ctx, Command{Name: "/bin/sh", Args: []string{"-c", "sleep 30"}}, nil)

	if err == nil {
		t.Fatal("a child that never finished was reported as success")
	}
	if time.Since(started) > 10*time.Second {
		t.Errorf("waited %s for a cancelled child", time.Since(started))
	}
	if !strings.Contains(err.Error(), context.DeadlineExceeded.Error()) {
		t.Errorf("err = %v, want it to say why it stopped", err)
	}
}

func TestExecRunnerPassesEnvironmentThrough(t *testing.T) {
	if _, err := os.Stat("/bin/sh"); err != nil {
		t.Skip("no /bin/sh; this project is Unix-first and says so")
	}

	var seen []string
	sink := sinkFunc(func(e Event) {
		if e.Status == StatusProgress {
			seen = append(seen, e.Message)
		}
	})

	err := ExecRunner{}.Run(context.Background(), Command{
		Name: "/bin/sh",
		Args: []string{"-c", `echo "$NVIM_APPNAME:$HOME"`},
		Env:  []string{"NVIM_APPNAME=chroma-nvim"},
	}, sink)
	if err != nil {
		t.Fatalf("Run: %v", err)
	}

	line := strings.Join(seen, "")
	if !strings.HasPrefix(line, "chroma-nvim:") {
		t.Errorf("output %q, want the added variable", line)
	}
	// Added to the environment rather than replacing it: the child is Neovim
	// and it needs the XDG variables the paths came from.
	if strings.HasSuffix(line, ":") {
		t.Errorf("output %q, want the inherited environment to survive", line)
	}
}

type sinkFunc func(Event)

func (f sinkFunc) Emit(e Event) { f(e) }

// containsEnv reports whether the environment carries exactly this entry.
func containsEnv(env []string, entry string) bool {
	for _, got := range env {
		if got == entry {
			return true
		}
	}
	return false
}
