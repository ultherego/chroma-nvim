package detect

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

func shipped(t *testing.T) component.Set {
	t.Helper()

	set, problems, err := component.Load(filepath.Join("..", "..", "..", "components"))
	if err != nil || len(problems) > 0 {
		t.Fatalf("loading the shipped contract: %v %v", err, problems)
	}
	return set
}

// present builds a lookup that knows about exactly these names.
func present(names ...string) Lookup {
	known := map[string]bool{}
	for _, name := range names {
		known[name] = true
	}
	return func(name string) bool { return known[name] }
}

// says builds a version reporter from a table.
func says(versions map[string]string) Version {
	return func(name string) string { return versions[name] }
}

func find(tools []Tool, name string) (Tool, bool) {
	for _, tool := range tools {
		for _, candidate := range tool.Names {
			if candidate == name {
				return tool, true
			}
		}
	}
	return Tool{}, false
}

// The four states are the point: "missing" was never enough of an answer,
// because absent-but-installable, absent-and-manual and present-but-too-old are
// three different problems with three different next steps.
func TestTheFourStates(t *testing.T) {
	set := shipped(t)
	arch := System{OS: "linux", Arch: "amd64", PackageManager: "pacman"}

	tools := Tools(set, []string{"core"}, arch,
		present("git", "curl", "tar", "unzip", "gzip", "cc", "tree-sitter", "fzf"),
		says(map[string]string{
			"git":         "2.51.0",
			"tree-sitter": "0.26.9",
			// Below the 0.36 the contract asks for.
			"fzf": "0.30.0",
		}))

	for _, tc := range []struct {
		name   string
		want   Status
		reason string
	}{
		{"git", Present, "there and new enough"},
		{"tree-sitter", Present, "there and new enough"},
		{"fzf", TooOld, "there, and older than the contract accepts"},
		{"rg", Installable, "absent, and pacman has a verified name for it"},
		{"yazi", Installable, "absent, and pacman has a verified name for it"},
	} {
		tool, found := find(tools, tc.name)
		if !found {
			t.Errorf("%s was not reported at all", tc.name)
			continue
		}
		if tool.Status != tc.want {
			t.Errorf("%s = %q, want %q — %s", tc.name, tool.Status, tc.want, tc.reason)
		}
	}
}

// A tool with no verified package name produces an instruction, not a guess.
func TestAnUnknownPackageIsManual(t *testing.T) {
	set := shipped(t)

	// A manager nothing has been verified against.
	tools := Tools(set, []string{"core"}, System{PackageManager: "apt-get"}, present(), says(nil))

	tool, found := find(tools, "rg")
	if !found {
		t.Fatal("rg was not reported")
	}
	if tool.Status != Manual {
		t.Errorf("rg = %q on a manager with no verified names, want %q", tool.Status, Manual)
	}
	if tool.Command != nil {
		t.Errorf("a command was built for a package nobody verified: %v", tool.Command)
	}
}

// And a machine with no package manager at all is every tool's manual case.
func TestNoPackageManagerMeansManual(t *testing.T) {
	set := shipped(t)

	for _, tool := range Tools(set, []string{"core"}, System{}, present(), says(nil)) {
		if tool.Status != Manual {
			t.Errorf("%v = %q with no package manager, want %q", tool.Names, tool.Status, Manual)
		}
	}
}

// The first name that is both present and acceptable answers, so an old
// terraform does not mask a good tofu.
func TestAnAlternativeCanAnswer(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform"}, System{PackageManager: "pacman"},
		present("tofu"), says(map[string]string{"tofu": "1.8.0"}))

	tool, found := find(tools, "terraform")
	if !found {
		t.Fatal("the terraform requirement was not reported")
	}
	if tool.Status != Present || tool.Found != "tofu" {
		t.Errorf("status = %q found = %q; tofu should satisfy it", tool.Status, tool.Found)
	}
}

// Nothing is handed to a shell, and the command shown is the command that would
// run — including the fact that it needs root.
func TestTheCommandIsArgvAndSaysItNeedsRoot(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core"}, System{PackageManager: "pacman"}, present(), says(nil))
	tool, _ := find(tools, "rg")

	if len(tool.Command) == 0 {
		t.Fatal("no command for an installable tool")
	}
	if tool.Command[0] != "sudo" {
		t.Errorf("command = %v, want it to say it needs root", tool.Command)
	}
	if tool.Package != "ripgrep" {
		t.Errorf("package = %q, want the name Arch actually uses", tool.Package)
	}
	for _, part := range tool.Command {
		if strings.ContainsAny(part, "|;&$`") {
			t.Errorf("command carries shell syntax: %q", part)
		}
	}
}

// Running as root, the sudo is neither needed nor present in every image.
func TestRootNeedsNoSudo(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core"}, System{PackageManager: "pacman", IsRoot: true}, present(), says(nil))
	tool, _ := find(tools, "rg")

	if len(tool.Command) == 0 || tool.Command[0] == "sudo" {
		t.Errorf("command = %v, want no sudo when already root", tool.Command)
	}
}

// One entry per requirement: a tool two components ask for is one thing to do.
func TestARequirementIsReportedOnce(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform", "vault", "ansible"}, System{}, present(), says(nil))

	counted := map[string]int{}
	for _, tool := range tools {
		counted[tool.Names[0]]++
	}
	for name, times := range counted {
		if times > 1 {
			t.Errorf("%s reported %d times", name, times)
		}
	}
}

// The levels come from the contract and decide what stops an installation.
func TestLevelsComeFromTheContract(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform"}, System{}, present(), says(nil))

	for _, tc := range []struct{ name, level string }{
		{"git", "required"},
		{"fzf", "recommended"},
		{"yazi", "optional"},
		{"terraform", "required"},
		{"terragrunt", "recommended"},
	} {
		tool, found := find(tools, tc.name)
		if !found {
			t.Errorf("%s was not reported", tc.name)
			continue
		}
		if tool.Level != tc.level {
			t.Errorf("%s is %q, want %q", tc.name, tool.Level, tc.level)
		}
		if tool.Required() != (tc.level == "required") {
			t.Errorf("%s: Required() disagrees with the level", tc.name)
		}
	}
}

func TestDetectSystemAnswersSomething(t *testing.T) {
	system := DetectSystem()
	if system.OS == "" || system.Arch == "" {
		t.Errorf("system = %+v, want an OS and an architecture", system)
	}
}
