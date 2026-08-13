package install

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Command is one external process. A struct rather than a variadic call, because
// everything the installer runs has to go through one place that can bound it,
// cancel it and log it. Args stay a slice: nothing here is ever handed to a
// shell.
type Command struct {
	Name string
	Args []string

	// Env is added to the environment this process already has, rather than
	// replacing it. The child is Neovim, and Neovim needs the XDG variables the
	// paths were resolved from.
	Env []string

	Dir string
}

// Event is what a step reports while it runs.
type Event struct {
	Step    string
	Status  string // start, progress, done, warning, failed
	Message string
}

// Statuses an event may carry.
const (
	StatusStart    = "start"
	StatusProgress = "progress"
	StatusDone     = "done"
	StatusWarning  = "warning"
	StatusFailed   = "failed"
)

// ProgressSink receives events. The plain CLI prints them as lines and the TUI
// turns them into its own messages; the backend knows about neither.
type ProgressSink interface {
	Emit(Event)
}

// Discard is a sink for callers with nothing to show.
type Discard struct{}

// Emit does nothing.
func (Discard) Emit(Event) {}

// Runner runs a command. An interface so that the installer can be tested
// without a Neovim, and so that a dry run has somewhere obvious to refuse.
type Runner interface {
	Run(ctx context.Context, cmd Command, sink ProgressSink) error
}

// ExecRunner runs commands for real.
type ExecRunner struct {
	// Log receives every line the child writes, which is where the detail goes:
	// the screen gets a status and a path to this.
	Log io.Writer
}

// Run starts the command, streams its output, and returns when it has finished
// or when the context says to stop. The context is not advisory:
// exec.CommandContext kills the child, which is what makes a bootstrap that
// hangs a failed installation rather than a terminal nobody can get back.
func (r ExecRunner) Run(ctx context.Context, cmd Command, sink ProgressSink) error {
	if sink == nil {
		sink = Discard{}
	}

	process := exec.CommandContext(ctx, cmd.Name, cmd.Args...)
	process.Dir = cmd.Dir
	process.Env = append(os.Environ(), cmd.Env...)

	// Killing a process does not close the pipes its children inherited, so
	// reading to EOF can outlive the cancellation. Measured in CI: a cancelled
	// `sh -c "sleep 30"` held this open for the full thirty seconds. WaitDelay
	// closes the pipes shortly after the context ends regardless.
	process.WaitDelay = 2 * time.Second

	output, err := process.StdoutPipe()
	if err != nil {
		return fmt.Errorf("reading the output of %s: %w", cmd.Name, err)
	}
	process.Stderr = process.Stdout

	if err := process.Start(); err != nil {
		return fmt.Errorf("running %s: %w", cmd.Name, err)
	}

	// Kept for the error message. The log has everything; a failure needs the
	// last few lines where somebody will read them.
	var (
		mu   sync.Mutex
		tail []string
	)

	// Buffered, so the goroutine can put its answer down and leave even if
	// nothing is waiting yet.
	scanned := make(chan error, 1)
	go func() {
		scanner := bufio.NewScanner(output)
		scanner.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for scanner.Scan() {
			line := scanner.Text()
			if r.Log != nil {
				fmt.Fprintln(r.Log, line)
			}
			if strings.TrimSpace(line) == "" {
				continue
			}
			sink.Emit(Event{Status: StatusProgress, Message: line})

			mu.Lock()
			tail = append(tail, line)
			if len(tail) > 20 {
				tail = tail[1:]
			}
			mu.Unlock()
		}

		// Whatever stopped the scan, the pipe still has to be emptied. A Scanner
		// stops on a line longer than its buffer, and stopping is not being
		// finished: the child goes on writing into a pipe nobody is reading,
		// fills it, and blocks forever. Measured — one line of two megabytes from
		// a child that then exited cleanly made this run until the test framework
		// killed it. The output really is lost; that is what the error says.
		err := scanner.Err()
		if err != nil {
			_, _ = io.Copy(io.Discard, output)
		}
		scanned <- err
	}()
	scanErr := <-scanned

	waitErr := process.Wait()

	mu.Lock()
	said := strings.Join(tail, "\n")
	mu.Unlock()

	// The context's own reason first, which is more useful than "signal: killed"
	// and truer than anything the other two could say about a run that was
	// cancelled.
	if ctxErr := ctx.Err(); ctxErr != nil && waitErr != nil {
		return fmt.Errorf("%s stopped: %w\n%s", cmd.Name, ctxErr, said)
	}

	// Then the child's own failure, which is what somebody is looking for. A
	// reading problem alongside it is worth naming and is not the headline.
	if waitErr != nil {
		if scanErr != nil {
			return fmt.Errorf("%s failed: %w\nits output could not be read either: %v\n%s", cmd.Name, waitErr, scanErr, said)
		}
		if said != "" {
			return fmt.Errorf("%s failed: %w\n%s", cmd.Name, waitErr, said)
		}
		return fmt.Errorf("%s failed: %w", cmd.Name, waitErr)
	}

	// And an exit status of zero is not success if this could not see what the
	// child did. The installer decides whether an editor bootstrapped correctly
	// from what it reads here; reporting success on output that was thrown away
	// would be deciding it from nothing.
	if scanErr != nil {
		return fmt.Errorf("the output of %s could not be read, so this cannot say whether it worked: %w", cmd.Name, scanErr)
	}

	return nil
}
