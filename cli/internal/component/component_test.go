package component

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// corpus is shared with the Lua reader, which is driven by the same files. Both
// sides being held to one set of documents is what makes "Go accepts, Lua
// rejects" a failing test rather than a difference somebody meets during an
// install.
const corpus = "../../../tests/fixtures/component-contract"

// TestCorpus reads each fixture on its own. Together in one directory, a reader
// that gave up after the first bad file would still report a problem and look
// correct.
func TestCorpus(t *testing.T) {
	for _, kind := range []string{"valid", "invalid"} {
		entries, err := os.ReadDir(filepath.Join(corpus, kind))
		if err != nil {
			t.Fatalf("reading the fixtures: %v", err)
		}
		if len(entries) == 0 {
			t.Fatalf("no %s fixtures, which would make this pass for nothing", kind)
		}

		for _, entry := range entries {
			t.Run(kind+"/"+entry.Name(), func(t *testing.T) {
				dir := t.TempDir()
				body, err := os.ReadFile(filepath.Join(corpus, kind, entry.Name()))
				if err != nil {
					t.Fatalf("reading %s: %v", entry.Name(), err)
				}
				if err := os.WriteFile(filepath.Join(dir, entry.Name()), body, 0o644); err != nil {
					t.Fatalf("writing the fixture: %v", err)
				}

				set, problems, err := Load(dir)
				if err != nil {
					t.Fatalf("Load: %v", err)
				}

				if kind == "valid" {
					if len(problems) > 0 {
						t.Errorf("refused a valid fixture: %v", problems)
					}
					if len(set) != 1 {
						t.Errorf("loaded %d components, want 1", len(set))
					}
					return
				}

				if len(problems) != 1 {
					t.Errorf("problems = %v, want exactly one", problems)
				}
				if len(set) != 0 {
					t.Errorf("loaded %d components from an invalid fixture", len(set))
				}
			})
		}
	}
}

// shipped is the contract this repository actually ships, three directories up
// from this package. Checking it here means a broken component fails the CLI
// build, not an install on somebody's machine.
func shipped(t *testing.T) Set {
	t.Helper()

	set, problems, err := Load(filepath.Join("..", "..", "..", "components"))
	if err != nil {
		t.Fatalf("loading the shipped contract: %v", err)
	}
	if len(problems) > 0 {
		t.Fatalf("shipped contract has problems: %v", problems)
	}
	if len(set) == 0 {
		t.Fatal("shipped contract is empty, which would satisfy every other check here")
	}
	return set
}

func TestShippedContractLoads(t *testing.T) {
	set := shipped(t)
	if set["core"] == nil {
		t.Error("no core component")
	}
}

func TestShippedContractResolves(t *testing.T) {
	if problems := shipped(t).ResolveProblems(); len(problems) > 0 {
		t.Errorf("shipped contract does not resolve: %v", problems)
	}
}

// Every tool is a name the installer will look for, so one with neither id nor
// any can never be satisfied and a component holding it can never be complete.
func TestShippedToolsAreLookupable(t *testing.T) {
	for _, id := range shipped(t).IDs() {
		component := shipped(t)[id]
		levels := map[string][]Tool{
			"required":    component.Tools.Required,
			"recommended": component.Tools.Recommended,
			"optional":    component.Tools.Optional,
		}
		for level, tools := range levels {
			for _, tool := range tools {
				if len(tool.Names()) == 0 {
					t.Errorf("%s: a %s tool has neither id nor any", id, level)
				}
				if tool.Reason == "" {
					t.Errorf("%s: %s has no reason", id, strings.Join(tool.Names(), "|"))
				}
			}
		}
	}
}

// The Lua side rejects the same things. Where these two disagree, one accepts a
// contract the other refuses, and the disagreement shows up during an install.
func TestLoadReportsBadFiles(t *testing.T) {
	cases := []struct {
		name     string
		files    map[string]string
		problems int
		contains string
	}{
		{
			name:     "not JSON",
			files:    map[string]string{"broken.json": "{ not json"},
			problems: 1,
			contains: "is not valid JSON",
		},
		{
			name:     "no id",
			files:    map[string]string{"anonymous.json": `{"contract": 5}`},
			problems: 1,
			contains: "has no id",
		},
		{
			name:     "a contract from the future",
			files:    map[string]string{"future.json": `{"contract": 99, "id": "future"}`},
			problems: 1,
			contains: "declares contract 99",
		},
		{
			name:     "a field it does not know",
			files:    map[string]string{"typo.json": `{"contract": 5, "id": "typo", "require": ["core"]}`},
			problems: 1,
			contains: "unknown field",
		},
		{
			name:     "an unknown field inside a tool",
			files:    map[string]string{"deep.json": `{"contract": 5, "id": "deep", "tools": {"required": [{"id": "x", "reason": "y", "min": "1.0"}]}}`},
			problems: 1,
			contains: "unknown field",
		},
		{
			name:     "a tool with both id and any",
			files:    map[string]string{"both.json": `{"contract": 5, "id": "both", "tools": {"required": [{"id": "x", "any": ["y"], "reason": "z"}]}}`},
			problems: 1,
			contains: "both id and any",
		},
		{
			name:     "a tool with neither",
			files:    map[string]string{"neither.json": `{"contract": 5, "id": "neither", "tools": {"required": [{"reason": "z"}]}}`},
			problems: 1,
			contains: "neither id nor any",
		},
		{
			name:     "a tool with no reason",
			files:    map[string]string{"silent.json": `{"contract": 5, "id": "silent", "tools": {"required": [{"id": "x"}]}}`},
			problems: 1,
			contains: "no reason",
		},
		{
			name:     "a document written for an older contract",
			files:    map[string]string{"old.json": `{"contract": 3, "id": "old"}`},
			problems: 1,
			contains: "declares contract 3",
		},
		{
			// Contract 5 removed `exact`, so the schema no longer has a way to
			// say "this machine must run exactly 1.35.2" about a tool that is
			// not Chroma's. It is refused as what it now is: a field the
			// contract does not define.
			name:     "a version pinned to one release",
			files:    map[string]string{"pinned.json": `{"contract": 5, "id": "pinned", "tools": {"required": [{"id": "x", "reason": "y", "version": {"exact": "1.2"}}]}}`},
			problems: 1,
			contains: `unknown field "exact"`,
		},
		{
			name:     "a version that says nothing",
			files:    map[string]string{"empty.json": `{"contract": 5, "id": "empty", "tools": {"required": [{"id": "x", "reason": "y", "version": {}}]}}`},
			problems: 1,
			contains: "says nothing",
		},
		{
			name:     "a min above its max",
			files:    map[string]string{"inverted.json": `{"contract": 5, "id": "inverted", "tools": {"required": [{"id": "x", "reason": "y", "version": {"min": "2.0", "max": "1.0"}}]}}`},
			problems: 1,
			contains: "above max",
		},
		{
			name:     "a version that is not one",
			files:    map[string]string{"prose.json": `{"contract": 5, "id": "prose", "tools": {"required": [{"id": "x", "reason": "y", "version": {"min": "latest"}}]}}`},
			problems: 1,
			contains: "not a version",
		},
		{
			name:     "an unknown field inside version",
			files:    map[string]string{"deepver.json": `{"contract": 5, "id": "deepver", "tools": {"required": [{"id": "x", "reason": "y", "version": {"minimum": "1.0"}}]}}`},
			problems: 1,
			contains: "unknown field",
		},
		{
			name: "two files, one id",
			files: map[string]string{
				"a.json": `{"contract": 5, "id": "same"}`,
				"b.json": `{"contract": 5, "id": "same"}`,
			},
			problems: 1,
			contains: "already declared",
		},
	}

	for _, one := range cases {
		t.Run(one.name, func(t *testing.T) {
			dir := write(t, one.files)

			_, problems, err := Load(dir)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if len(problems) != one.problems {
				t.Fatalf("problems = %v, want %d", problems, one.problems)
			}
			if !strings.Contains(problems[0], one.contains) {
				t.Errorf("problem %q does not mention %q", problems[0], one.contains)
			}
		})
	}
}

func TestResolveProblems(t *testing.T) {
	cases := []struct {
		name     string
		files    map[string]string
		contains string
	}{
		{
			name:     "a dependency that is not declared",
			files:    map[string]string{"orphan.json": `{"contract": 5, "id": "orphan", "requires": ["nothing"]}`},
			contains: `requires "nothing"`,
		},
		{
			name: "a cycle",
			files: map[string]string{
				"a.json": `{"contract": 5, "id": "a", "requires": ["b"]}`,
				"b.json": `{"contract": 5, "id": "b", "requires": ["a"]}`,
			},
			contains: "cycle",
		},
	}

	for _, one := range cases {
		t.Run(one.name, func(t *testing.T) {
			set, problems, err := Load(write(t, one.files))
			if err != nil || len(problems) > 0 {
				t.Fatalf("Load: %v %v", err, problems)
			}

			resolved := set.ResolveProblems()
			if len(resolved) == 0 {
				t.Fatal("no problem reported")
			}
			if !strings.Contains(resolved[0], one.contains) {
				t.Errorf("problem %q does not mention %q", resolved[0], one.contains)
			}
		})
	}
}

// A diamond is not a cycle, and a resolver that cannot tell them apart refuses
// perfectly ordinary contracts.
func TestDiamondIsNotACycle(t *testing.T) {
	set, problems, err := Load(write(t, map[string]string{
		"core.json": `{"contract": 5, "id": "core"}`,
		"mid.json":  `{"contract": 5, "id": "mid", "requires": ["core"]}`,
		"leaf.json": `{"contract": 5, "id": "leaf", "requires": ["mid", "core"]}`,
	}))
	if err != nil || len(problems) > 0 {
		t.Fatalf("Load: %v %v", err, problems)
	}

	if resolved := set.ResolveProblems(); len(resolved) > 0 {
		t.Errorf("a diamond was reported as a problem: %v", resolved)
	}
}

func TestMissingUsesAlternatives(t *testing.T) {
	component := &Component{
		Tools: Tools{Required: []Tool{
			{Any: []string{"neither", "nor"}, Reason: "a tool with two names"},
			{ID: "present", Reason: "a tool with one"},
		}},
	}

	missing := component.Missing(func(name string) bool { return name == "present" || name == "nor" })
	if len(missing) != 0 {
		t.Errorf("missing = %v, want none: either name should satisfy it", missing)
	}

	missing = component.Missing(func(string) bool { return false })
	if len(missing) != 2 {
		t.Errorf("missing = %v, want both", missing)
	}
}

// The false positive this whole change exists to prevent: the executable is
// there, LookPath is happy, and it is too old to do the job.
func TestPresentButTooOldIsNotSatisfied(t *testing.T) {
	tool := Tool{ID: "tree-sitter", Reason: "parsers", Version: &Version{Min: "0.26.1"}}
	present := func(string) bool { return true }

	if _, ok := Satisfy(tool, present, func(string) string { return "0.25.9" }); ok {
		t.Error("0.25.9 satisfies a floor of 0.26.1")
	}
	if _, ok := Satisfy(tool, present, func(string) string { return "0.26.1" }); !ok {
		t.Error("the floor itself should satisfy the floor")
	}
	if _, ok := Satisfy(tool, present, func(string) string { return "1.0" }); !ok {
		t.Error("a newer version should satisfy a floor")
	}

	// A tool that will not say what it is cannot be shown to meet a constraint.
	if _, ok := Satisfy(tool, present, func(string) string { return "" }); ok {
		t.Error("an unknown version satisfies nothing that was constrained")
	}
}

// An old terraform must not mask an acceptable tofu.
func TestAlternativesArePickedByVersionToo(t *testing.T) {
	tool := Tool{Any: []string{"terraform", "tofu"}, Reason: "the runner", Version: &Version{Min: "1.5"}}

	name, ok := Satisfy(tool, func(string) bool { return true }, func(n string) string {
		if n == "terraform" {
			return "1.0"
		}
		return "1.9"
	})
	if !ok || name != "tofu" {
		t.Errorf("name = %q ok = %v; tofu is the one that meets the floor", name, ok)
	}
}

func TestCompareVersions(t *testing.T) {
	cases := []struct {
		a, b string
		want int
	}{
		{"1.2.3", "1.2.3", 0},
		{"1.2", "1.2.0", 0},
		{"v2.19", "2.19", 0},
		{"0.26.1", "0.26.9", -1},
		{"1.10", "1.9", 1},
		{"2.0.0-rc1", "2.0.0", 0},
	}

	for _, one := range cases {
		if got := CompareVersions(one.a, one.b); got != one.want {
			t.Errorf("CompareVersions(%q, %q) = %d, want %d", one.a, one.b, got, one.want)
		}
	}
}

func write(t *testing.T, files map[string]string) string {
	t.Helper()

	dir := t.TempDir()
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(contents), 0o600); err != nil {
			t.Fatalf("writing %s: %v", name, err)
		}
	}
	return dir
}
