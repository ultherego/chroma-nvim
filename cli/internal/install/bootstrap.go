package install

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// BootstrapTimeout bounds one headless step.
//
// Generous, because it covers compiling treesitter parsers on a machine whose
// speed nobody here knows, and finite because the alternative is a `chroma
// install` that hangs with no way to tell whether it is working. The editor
// bounds its own steps as well; this is the bound that holds when the editor
// itself is what stopped making progress.
const BootstrapTimeout = 30 * time.Minute

// Bootstrap makes the placed configuration install its own plugins, tools and
// parsers.
//
// The knowledge of *how* lives in the tree that was just placed —
// `lua/chroma/bootstrap.lua`, which the source validation required before any
// of this started. This function knows only how to run it and how long to wait.
func (tx *Transaction) Bootstrap(ctx context.Context, paths Paths, runner Runner, sink ProgressSink) error {
	if !tx.Placed {
		return fmt.Errorf("nothing has been placed at %s to bootstrap", paths.ConfigDir)
	}
	return runStep(ctx, paths, runner, sink, "install", nil)
}

// Verify asks the placed configuration whether it is a Chroma that starts, and
// whether it is the one that was asked for.
func (tx *Transaction) Verify(ctx context.Context, paths Paths, expected []string, runner Runner, sink ProgressSink) error {
	if !tx.Placed {
		return fmt.Errorf("nothing has been placed at %s to verify", paths.ConfigDir)
	}
	return runStep(ctx, paths, runner, sink, "verify", expected)
}

// runStep drives one verb of the bootstrap entrypoint.
func runStep(ctx context.Context, paths Paths, runner Runner, sink ProgressSink, step string, expected []string) error {
	if sink == nil {
		sink = Discard{}
	}
	if runner == nil {
		return fmt.Errorf("no runner to run %s with", step)
	}

	// Always bounded. A caller that forgot is the case this is for: the doc
	// says every subprocess gets a deadline, and "every" cannot depend on
	// being remembered.
	if _, bounded := ctx.Deadline(); !bounded {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(ctx, BootstrapTimeout)
		defer cancel()
	}

	nvim, err := exec.LookPath("nvim")
	if err != nil {
		return fmt.Errorf("nvim is not on PATH, so the installed configuration cannot be %sed: %w", step, err)
	}

	cmd := Command{
		Name: nvim,
		Args: []string{
			"--headless",
			"-c", fmt.Sprintf("lua require(\"chroma.bootstrap\").run(%s)", luaArgs(step, expected)),
			"-c", "qa!",
		},
	}

	// The isolated installation is only reachable through NVIM_APPNAME. The
	// default one must not have it set at all — Neovim finds its own directory,
	// and setting the variable to "nvim" would be describing that as something
	// it is not.
	if paths.AppName != "" {
		cmd.Env = append(cmd.Env, "NVIM_APPNAME="+paths.AppName)
	}

	sink.Emit(Event{Step: step, Status: StatusStart})
	if err := runner.Run(ctx, cmd, sink); err != nil {
		sink.Emit(Event{Step: step, Status: StatusFailed, Message: err.Error()})
		return fmt.Errorf("%s of the installed configuration failed: %w", step, err)
	}
	sink.Emit(Event{Step: step, Status: StatusDone})

	return nil
}

// luaArgs renders the arguments to `run` as a Lua expression.
//
// Component ids come from the contract, which allows neither quotes nor
// backslashes in them — but this builds a string that another language will
// execute, so it quotes rather than trusting that. `%q` on a Lua string is the
// same escaping Go uses, which is what Lua's own long-bracket-free syntax
// accepts.
func luaArgs(step string, expected []string) string {
	rendered := fmt.Sprintf("%q", step)
	if expected == nil {
		return rendered
	}

	quoted := make([]string, 0, len(expected))
	for _, id := range expected {
		quoted = append(quoted, fmt.Sprintf("%q", id))
	}
	return fmt.Sprintf("%s, { %s }", rendered, strings.Join(quoted, ", "))
}
