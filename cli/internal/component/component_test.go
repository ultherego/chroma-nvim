package component

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

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
			files:    map[string]string{"anonymous.json": `{"contract": 1}`},
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
			files:    map[string]string{"typo.json": `{"contract": 1, "id": "typo", "require": ["core"]}`},
			problems: 1,
			contains: "unknown field",
		},
		{
			name:     "an unknown field inside a tool",
			files:    map[string]string{"deep.json": `{"contract": 1, "id": "deep", "tools": {"required": [{"id": "x", "reason": "y", "min": "1.0"}]}}`},
			problems: 1,
			contains: "unknown field",
		},
		{
			name:     "a tool with both id and any",
			files:    map[string]string{"both.json": `{"contract": 1, "id": "both", "tools": {"required": [{"id": "x", "any": ["y"], "reason": "z"}]}}`},
			problems: 1,
			contains: "both id and any",
		},
		{
			name:     "a tool with neither",
			files:    map[string]string{"neither.json": `{"contract": 1, "id": "neither", "tools": {"required": [{"reason": "z"}]}}`},
			problems: 1,
			contains: "neither id nor any",
		},
		{
			name:     "a tool with no reason",
			files:    map[string]string{"silent.json": `{"contract": 1, "id": "silent", "tools": {"required": [{"id": "x"}]}}`},
			problems: 1,
			contains: "no reason",
		},
		{
			name: "two files, one id",
			files: map[string]string{
				"a.json": `{"contract": 1, "id": "same"}`,
				"b.json": `{"contract": 1, "id": "same"}`,
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
			files:    map[string]string{"orphan.json": `{"contract": 1, "id": "orphan", "requires": ["nothing"]}`},
			contains: `requires "nothing"`,
		},
		{
			name: "a cycle",
			files: map[string]string{
				"a.json": `{"contract": 1, "id": "a", "requires": ["b"]}`,
				"b.json": `{"contract": 1, "id": "b", "requires": ["a"]}`,
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
		"core.json": `{"contract": 1, "id": "core"}`,
		"mid.json":  `{"contract": 1, "id": "mid", "requires": ["core"]}`,
		"leaf.json": `{"contract": 1, "id": "leaf", "requires": ["mid", "core"]}`,
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
