package detect

import (
	"bytes"
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

// The states are what is known, not what to do about it: present, present and
// too old, absent.
func TestTheThreeStates(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core"},
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
		{"rg", Absent, "not there"},
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

// The decision this package exists to hold: a tool the user owns is never a
// reason to stop. Chroma installs Chroma.
func TestAnExternalToolNeverBlocks(t *testing.T) {
	set := shipped(t)

	// Nothing on this machine at all.
	tools := Tools(set, []string{"core", "terraform", "kubernetes", "ansible", "aws"}, present(), says(nil))

	for _, name := range []string{"terraform", "kubectl", "ansible-playbook", "aws"} {
		tool, found := find(tools, name)
		if !found {
			continue // not every one of these is in every component
		}
		if !tool.External {
			t.Errorf("%s is not marked external, so its absence would stop an installation", name)
		}
		if tool.Blocking() {
			t.Errorf("%s blocks an installation; choosing a component asks for Chroma's features, not for the CLI", name)
		}
	}
}

// And the other half of the same boundary: without git there are no plugins,
// so that one does stop.
func TestChromasOwnRequiredToolBlocks(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core"}, present(), says(nil))

	git, found := find(tools, "git")
	if !found {
		t.Fatal("git was not reported")
	}
	if git.External {
		t.Error("git is marked external; it is Chroma's own requirement")
	}
	if !git.Blocking() {
		t.Error("an absent git does not block, but lazy.nvim cannot clone without it")
	}
}

// A recommended tool of Chroma's own is still not a reason to refuse.
func TestOnlyRequiredBlocks(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core"}, present(), says(nil))

	fzf, found := find(tools, "fzf")
	if !found {
		t.Fatal("fzf was not reported")
	}
	if fzf.Level != "recommended" {
		t.Fatalf("fzf is %q; this test assumed recommended", fzf.Level)
	}
	if fzf.Blocking() {
		t.Error("an absent recommended tool blocks an installation")
	}
}

// The first name that is both present and acceptable answers, so an old
// terraform does not mask a good tofu.
func TestAnAlternativeCanAnswer(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform"},
		present("tofu"), says(map[string]string{"tofu": "1.8.0"}))

	tool, found := find(tools, "terraform")
	if !found {
		t.Fatal("the terraform requirement was not reported")
	}
	if tool.Status != Present || tool.Found != "tofu" {
		t.Errorf("status = %q found = %q; tofu should satisfy it", tool.Status, tool.Found)
	}
}

// One entry per requirement: a tool two components ask for is one thing to know.
func TestARequirementIsReportedOnce(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform", "vault", "ansible"}, present(), says(nil))

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

// The levels come from the contract.
func TestLevelsComeFromTheContract(t *testing.T) {
	set := shipped(t)

	tools := Tools(set, []string{"core", "terraform"}, present(), says(nil))

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
	}
}

// A tool both core and a component ask for is Chroma's own, whichever the
// caller happened to enumerate first. `doctor` walks the contract in sorted
// order, so anything sorting before "core" would otherwise make a tool Chroma
// cannot run without look like the user's — and stop it blocking.
func TestCoreWinsWhicheverComponentIsSeenFirst(t *testing.T) {
	set := component.Set{
		"ansible": {ID: "ansible", Tools: component.Tools{
			Recommended: []component.Tool{{ID: "git", Reason: "cloning roles"}},
		}},
		"core": {ID: "core", Tools: component.Tools{
			Required: []component.Tool{{ID: "git", Reason: "lazy.nvim clones plugins"}},
		}},
	}

	// Sorted order, which is what doctor passes: ansible is seen first.
	tools := Tools(set, []string{"ansible", "core"}, present(), says(nil))

	git, found := find(tools, "git")
	if !found {
		t.Fatal("git was not reported")
	}
	if git.External {
		t.Error("git is external because a component named it before core did")
	}
	if git.Level != "required" {
		t.Errorf("level = %q, want required: core cannot work without it", git.Level)
	}
	if !git.Blocking() {
		t.Error("an absent git does not block, because a component got to it first")
	}
}

func TestSplitPutsEachToolOnOneSide(t *testing.T) {
	set := shipped(t)

	own, external := Split(Tools(set, []string{"core", "terraform"}, present(), says(nil)))

	if len(own) == 0 || len(external) == 0 {
		t.Fatalf("split gave %d own and %d external", len(own), len(external))
	}
	for _, tool := range own {
		if tool.Component != "core" {
			t.Errorf("%v is on the Chroma side but came from %q", tool.Names, tool.Component)
		}
	}
	for _, tool := range external {
		if tool.Component == "core" {
			t.Errorf("%v is on the external side but came from core", tool.Names)
		}
	}
}

// The wording is the substance: an absent kubectl is a fact about the machine,
// and a report that shouts about it says the installation is broken when it is
// not.
func TestTheReportDoesNotCallAMissingToolAFailure(t *testing.T) {
	set := shipped(t)

	_, external := Split(Tools(set, []string{"core", "kubernetes"}, present(), says(nil)))

	var buffer bytes.Buffer
	RenderExternal(&buffer, external)
	text := buffer.String()

	if !strings.Contains(text, "not found") {
		t.Errorf("the report does not say what is not found:\n%s", text)
	}
	if !strings.Contains(text, "does not install") {
		t.Errorf("the report does not say Chroma will not install these:\n%s", text)
	}
	for _, shouted := range []string{"ERROR", "FAIL", "missing dependency", "required but"} {
		if strings.Contains(text, shouted) {
			t.Errorf("the report says %q about a tool that is simply the user's to install:\n%s", shouted, text)
		}
	}
}

func TestDetectSystemAnswersSomething(t *testing.T) {
	system := DetectSystem()
	if system.OS == "" || system.Arch == "" {
		t.Errorf("system = %+v, want an OS and an architecture", system)
	}
}
