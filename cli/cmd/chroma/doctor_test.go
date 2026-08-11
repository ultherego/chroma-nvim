package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
	"github.com/ultherego/chroma-nvim/cli/internal/release"
)

// contractInto gives an installation the component contract this repository
// ships, which is what a real one has under it.
func contractInto(t *testing.T, configDir string) {
	t.Helper()

	source := contractSource()
	entries, err := os.ReadDir(source)
	if err != nil {
		t.Fatalf("reading the contract: %v", err)
	}

	target := filepath.Join(configDir, "components")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		contents, err := os.ReadFile(filepath.Join(source, entry.Name()))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(target, entry.Name()), contents, 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

// contractSource is where this repository's component contract is, resolved
// once and absolutely: a test that chdirs elsewhere must not change what a
// relative path means to the tests that run after it.
var contractSource = func() func() string {
	dir, err := filepath.Abs(filepath.Join("..", "..", "..", "components"))
	if err != nil {
		panic(err)
	}
	return func() string { return dir }
}()

// say runs a command and gives back what it printed.
func say(t *testing.T, run func(*os.File, *os.File) int) (string, int) {
	t.Helper()

	out, err := os.CreateTemp(t.TempDir(), "out")
	if err != nil {
		t.Fatal(err)
	}
	defer out.Close()

	code := run(out, out)

	printed, err := os.ReadFile(out.Name())
	if err != nil {
		t.Fatal(err)
	}
	return string(printed), code
}

// Measured on a working installation, before this: `cd /tmp && chroma doctor`
// answered "no components directory in . — is that a Chroma Neovim tree?" and
// exited 2. The question doctor is for is whether the Chroma on this machine is
// healthy, and the answer to that does not depend on where somebody is standing.
func TestDoctorFindsTheInstallationRatherThanTheCurrentDirectory(t *testing.T) {
	paths := machine(t)
	contractInto(t, paths.ConfigDir)

	here := mustCwd(t)
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(here) })

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor(nil, out, errOut)
	})

	if strings.Contains(printed, "no components directory") {
		t.Errorf("doctor read the current directory instead of the installation:\n%s", printed)
	}
	// Either is fine and neither is the point: the runner may be missing a tool
	// Chroma needs, which is a fact about the runner. What is under test is
	// which installation the report is about.
	if code != exitOK && code != exitPreflight {
		t.Errorf("exit %d:\n%s", code, printed)
	}
	if !strings.Contains(printed, paths.ConfigDir) {
		t.Errorf("the report does not say which installation it is about:\n%s", printed)
	}
}

// A report about an installation is a report about the components its owner
// chose. Somebody who turned Kubernetes off is not missing kubectl.
func TestDoctorReportsOnlyTheComponentsInForce(t *testing.T) {
	paths := machine(t)
	contractInto(t, paths.ConfigDir)

	if err := os.MkdirAll(filepath.Dir(paths.SelectionFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(paths.SelectionFile, []byte(`{"schema":1,"selected":["terraform"]}`), 0o644); err != nil {
		t.Fatal(err)
	}

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor(nil, out, errOut)
	})
	if code != exitOK && code != exitPreflight {
		t.Fatalf("exit %d:\n%s", code, printed)
	}

	if !strings.Contains(printed, "terraform") {
		t.Errorf("the chosen component is not in the report:\n%s", printed)
	}
	for _, absent := range []string{"kubectl", "helm", "ansible", "aws"} {
		if strings.Contains(printed, absent) {
			t.Errorf("%s is reported although its component is not enabled:\n%s", absent, printed)
		}
	}
}

// And with no selection document at all it is core alone, not everything.
func TestDoctorWithNoSelectionReportsCoreAlone(t *testing.T) {
	paths := machine(t)
	contractInto(t, paths.ConfigDir)

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor(nil, out, errOut)
	})
	if code != exitOK && code != exitPreflight {
		t.Fatalf("exit %d:\n%s", code, printed)
	}
	for _, absent := range []string{"terraform", "kubectl", "ansible"} {
		if strings.Contains(printed, absent) {
			t.Errorf("%s is reported for an installation that enabled nothing:\n%s", absent, printed)
		}
	}
}

// `--tree` is the developer override and keeps reporting the whole contract:
// a checkout has no selection to narrow it by.
func TestDoctorWithATreeReportsTheWholeContract(t *testing.T) {
	machine(t)

	checkout := t.TempDir()
	contractInto(t, checkout)

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor([]string{"--tree", checkout}, out, errOut)
	})
	if code != exitOK && code != exitPreflight {
		t.Fatalf("exit %d:\n%s", code, printed)
	}
	if !strings.Contains(printed, "not an installation") {
		t.Errorf("the report does not say it is about a checkout:\n%s", printed)
	}
	if !strings.Contains(printed, "terraform") || !strings.Contains(printed, "kubectl") {
		t.Errorf("a checkout should report the whole contract:\n%s", printed)
	}
}

// With nothing installed, doctor says so — and says it the same way every other
// managed command does.
func TestDoctorWithNoInstallationSaysSo(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", root)
	for _, pair := range [][2]string{
		{"XDG_CONFIG_HOME", "config"}, {"XDG_DATA_HOME", "data"},
		{"XDG_STATE_HOME", "state"}, {"XDG_CACHE_HOME", "cache"},
	} {
		t.Setenv(pair[0], filepath.Join(root, pair[1]))
	}

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor(nil, out, errOut)
	})
	if code == exitOK {
		t.Errorf("doctor reported success with nothing installed:\n%s", printed)
	}
	if !strings.Contains(printed, "No Chroma installation is recorded") {
		t.Errorf("the refusal does not say what is wrong:\n%s", printed)
	}
}

// **Point 6, on the public entrypoint.** README documents `chroma install`, and
// it used to refuse: "nothing to install: name a release with --version".
func TestAPlainInstallAsksForTheLatestRelease(t *testing.T) {
	// Nothing recorded: with an installation already on the machine this would
	// be refused as a second one, long before it decided which version to ask
	// for.
	empty(t)

	var asked string
	real := releaseSource
	releaseSource = func(version string) preparer {
		asked = version
		return refuses{}
	}
	t.Cleanup(func() { releaseSource = real })

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdInstall([]string{"--non-interactive", "--components", "", "--yes"}, out, errOut)
	})

	if asked != release.Latest {
		t.Errorf("the plain form asked for %q, want %q:\n%s", asked, release.Latest, printed)
	}
	if code == exitMisuse {
		t.Errorf("the plain form was refused as misuse:\n%s", printed)
	}
	if strings.Contains(printed, "nothing to install") {
		t.Errorf("the plain form still refuses to install anything:\n%s", printed)
	}
}

// refuses stands in for the network: it proves which version was asked for
// without going and fetching it.
type refuses struct{}

func (refuses) Prepare(context.Context) (install.PreparedSource, error) {
	return install.PreparedSource{}, errors.New("not reaching the network in a test")
}

func mustCwd(t *testing.T) string {
	t.Helper()
	dir, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	return dir
}
