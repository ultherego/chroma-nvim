package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/plan"
)

// pretending puts a PATH in front of the real one holding scripts that answer
// `--version` with whatever this test wants them to say.
func pretending(t *testing.T, versions map[string]string) {
	t.Helper()

	dir := t.TempDir()
	for name, says := range versions {
		script := fmt.Sprintf("#!/bin/sh\nprintf '%%s\\n' %q\n", says)
		if err := os.WriteFile(filepath.Join(dir, name), []byte(script), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir+string(os.PathListSeparator)+os.Getenv("PATH"))
}

// **Point 11.** The plan and the report disagree about the same machine.
//
// `doctor` reads what a tool says its version is and holds it to the floor the
// contract states. The plan asks only whether the name is on PATH, so a git old
// enough that lazy.nvim cannot use it is `Present`, and the installation goes
// ahead against a machine that cannot run it.
func TestThePlanHoldsToolsToTheSameFloorsAsDoctor(t *testing.T) {
	empty(t)
	pretending(t, map[string]string{
		"git":         "git version 2.18.0",
		"tree-sitter": "0.25.0",
		"curl":        "curl 8.5.0",
		"tar":         "tar (GNU tar) 1.35",
		"unzip":       "UnZip 6.00",
		"gzip":        "gzip 1.12",
		"cc":          "cc (GCC) 13.3.0",
	})

	set, problems, err := component.Load(contractSource())
	if err != nil || len(problems) > 0 {
		t.Fatalf("Load: %v %v", err, problems)
	}

	built := plan.Build(set, []string{"core"}, describeTools)
	if built.Complete() {
		var stale []string
		for _, tool := range built.Tools {
			if !tool.External && tool.Level == "required" {
				stale = append(stale, strings.Join(tool.Names, " or "))
			}
		}
		t.Errorf("the plan is complete on a machine with git 2.18 and tree-sitter 0.25; required own tools it accepted: %s", strings.Join(stale, ", "))
	}

	printed, code := say(t, func(out, errOut *os.File) int {
		return cmdDoctor([]string{"--tree", filepath.Dir(contractSource())}, out, errOut)
	})
	if code != exitPreflight {
		t.Errorf("doctor exited %d on the same machine, want %d:\n%s", code, exitPreflight, printed)
	}
}

// A tool that is only recommended, and too old, is a fact about the machine and
// not a reason to refuse an installation. The distinction is the whole of
// Complete().
func TestATooOldRecommendedToolDoesNotStopAnInstallation(t *testing.T) {
	empty(t)
	pretending(t, map[string]string{
		"git": "git version 2.45.0", "tree-sitter": "0.26.9", "curl": "curl 8.5.0",
		"tar": "tar (GNU tar) 1.35", "unzip": "UnZip 6.00", "gzip": "gzip 1.12",
		"cc": "cc (GCC) 13.3.0", "fzf": "0.20.0", "rg": "ripgrep 14.1.0",
		"fd": "fd 9.0.0", "bat": "bat 0.24.0",
	})

	set, _, err := component.Load(contractSource())
	if err != nil {
		t.Fatal(err)
	}
	if built := plan.Build(set, []string{"core"}, describeTools); !built.Complete() {
		t.Error("an old but merely recommended tool stopped the installation")
	}
}

// **Point 14a.** `--tree` means the same thing to both commands, or it means
// nothing.
func TestTreeMeansTheSameThingToDoctorAndComponents(t *testing.T) {
	empty(t)
	checkout := t.TempDir()
	contractInto(t, checkout)

	doctorSaid, doctorCode := say(t, func(out, errOut *os.File) int {
		return cmdDoctor([]string{"--tree", checkout}, out, errOut)
	})
	listSaid, listCode := say(t, func(out, errOut *os.File) int {
		return cmdComponents([]string{"--tree", checkout}, out, errOut)
	})

	if doctorCode != exitOK && doctorCode != exitPreflight {
		t.Fatalf("doctor --tree exited %d:\n%s", doctorCode, doctorSaid)
	}
	if listCode != exitOK {
		t.Errorf("components --tree exited %d on the tree doctor read happily:\n%s", listCode, listSaid)
	}
	if !strings.Contains(listSaid, "terraform") {
		t.Errorf("components --tree listed nothing useful:\n%s", listSaid)
	}
}
