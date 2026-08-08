package toolver

import (
	"os"
	"path/filepath"
	"testing"
)

// The parsing, against the shapes these tools really print. The strings are
// what they produced on a machine, not what documentation says they produce.
func TestParsesRealOutputShapes(t *testing.T) {
	cases := []struct {
		name   string
		script string
		want   string
	}{
		{"git", `echo "git version 2.55.0"`, "2.55.0"},
		{"tree-sitter", `echo "tree-sitter 0.26.9"`, "0.26.9"},
		{"kubectl", "echo 'Client Version: v1.36.3'; echo 'Kustomize Version: v5.8.1'", "1.36.3"},
		{"helm", `echo 'v4.2.2+gd8a5d54'`, "4.2.2"},
		{"ansible", `echo "ansible [core 2.21.2]"`, "2.21.2"},
		{"unzip", "echo 'caution: both -n and -o specified'; echo 'UnZip 6.00 of 20 April 2009, by Info-ZIP.'", "6.00"},
		// The first line is the tool's own; several print their dependencies next.
		{"fd", "echo 'fd 10.4.2'; echo 'built with 1.2.3'", "10.4.2"},
	}

	for _, one := range cases {
		t.Run(one.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, one.name)
			if err := os.WriteFile(path, []byte("#!/bin/sh\n"+one.script+"\n"), 0o700); err != nil {
				t.Fatalf("writing the fake: %v", err)
			}

			t.Setenv("PATH", dir)
			if got := Of(one.name); got != one.want {
				t.Errorf("Of(%q) = %q, want %q", one.name, got, one.want)
			}
		})
	}
}

// A tool that is not there, and one that answers with nothing useful, both come
// back as unknown rather than as a plausible number.
func TestUnknownVersions(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "silent")
	if err := os.WriteFile(path, []byte("#!/bin/sh\necho 'no numbers here'\n"), 0o700); err != nil {
		t.Fatalf("writing the fake: %v", err)
	}
	t.Setenv("PATH", dir)

	if got := Of("silent"); got != "" {
		t.Errorf("Of(silent) = %q, want empty", got)
	}
	if got := Of("definitely-not-installed"); got != "" {
		t.Errorf("Of(missing) = %q, want empty", got)
	}
}
