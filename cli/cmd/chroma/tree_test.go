package main

import (
	"os"
	"path/filepath"
	"testing"
)

// bare is a Chroma tree that requires nothing of the machine.
//
// The lock tests used to install from this repository, whose core component
// requires tree-sitter among others. On a machine without them the plan is
// incomplete, install stops at the preflight — which is before the lock, since
// the lock is taken only once there is something to lock — and a test about
// locking failed for a reason that has nothing to do with locking. Measured in
// a container without those tools, which is what the CI runner is.
//
// It is the minimum LocalSource insists on, plus a contract with one component
// and no tools in it.
func bare(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	for path, contents := range map[string]string{
		"init.lua":                 "-- nothing to load\n",
		"lazy-lock.json":           "{}\n",
		"lua/chroma/bootstrap.lua": "return { setup = function() end }\n",
		"components/core.json":     `{"contract":5,"id":"core","name":"Core","description":"The editor itself.","requires":[],"tools":{}}`,
	} {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}
