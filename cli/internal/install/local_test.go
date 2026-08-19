package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// tree builds something that looks like a Chroma checkout. Each case then
// breaks exactly one thing about it, which is the only way to know that the
// check being tested is the one that fired.
func tree(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	write(t, filepath.Join(root, "init.lua"), "-- a configuration\n")
	write(t, filepath.Join(root, "lazy-lock.json"), "{}\n")

	if err := os.MkdirAll(filepath.Join(root, "lua", "chroma"), 0o755); err != nil {
		t.Fatalf("creating lua/chroma: %v", err)
	}
	write(t, filepath.Join(root, "lua", "chroma", "bootstrap.lua"), "return {}\n")

	if err := os.MkdirAll(filepath.Join(root, "components"), 0o755); err != nil {
		t.Fatalf("creating components: %v", err)
	}
	write(t, filepath.Join(root, "components", "core.json"),
		`{"contract": 5, "id": "core", "name": "Core editor"}`+"\n")
	write(t, filepath.Join(root, "components", "terraform.json"),
		`{"contract": 5, "id": "terraform", "name": "Terraform", "requires": ["core"]}`+"\n")

	// Two, so a tree installed by these tests is one that asks a question. A
	// single theme would never exercise the choice, and none would never
	// exercise the document.
	write(t, filepath.Join(root, "themes.json"), `{
  "schema": 1,
  "default": "first",
  "themes": [
    { "id": "first", "name": "The first one", "colorscheme": "first-dark" },
    { "id": "second", "name": "The second one", "colorscheme": "second" }
  ]
}
`)

	return root
}

func write(t *testing.T, path, contents string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatalf("writing %s: %v", path, err)
	}
}

func TestLocalSourceAcceptsAChromaTree(t *testing.T) {
	root := tree(t)

	prepared, err := LocalSource{Root: root}.Prepare(context.Background())
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}

	if prepared.Root != root {
		t.Errorf("Root = %q, want %q", prepared.Root, root)
	}
	if prepared.Contract != component.Contract {
		t.Errorf("Contract = %d, want %d", prepared.Contract, component.Contract)
	}
	// A tree is not a release, and an installation with no version is one
	// `update` cannot reason about. That is a property, not an oversight.
	if prepared.Version != "" {
		t.Errorf("Version = %q, want empty for a source tree", prepared.Version)
	}
	if prepared.Cleanup == nil {
		t.Fatal("Cleanup is nil")
	}
	if err := prepared.Cleanup(); err != nil {
		t.Errorf("Cleanup: %v", err)
	}
}

// The tree this repository ships is the one the CLI will really be pointed at
// during development, so it is checked rather than assumed to match the fixture
// above.
func TestLocalSourceAcceptsThisRepository(t *testing.T) {
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("resolving the repository root: %v", err)
	}

	source := LocalSource{Root: root}
	if _, err := source.Prepare(context.Background()); err != nil {
		t.Fatalf("Prepare on this repository: %v", err)
	}
}

func TestLocalSourceRefusesWhatIsNotAChromaTree(t *testing.T) {
	for _, tc := range []struct {
		name    string
		break_  func(t *testing.T, root string) string
		mention string
	}{
		{
			name:    "a relative path",
			break_:  func(_ *testing.T, _ string) string { return "some/tree" },
			mention: "not an absolute path",
		},
		{
			name:    "a path that is not there",
			break_:  func(_ *testing.T, root string) string { return filepath.Join(root, "elsewhere") },
			mention: "elsewhere",
		},
		{
			name: "a file rather than a directory",
			break_: func(t *testing.T, root string) string {
				path := filepath.Join(root, "init.lua")
				return path
			},
			mention: "not a directory",
		},
		{
			name: "no init.lua",
			break_: func(t *testing.T, root string) string {
				remove(t, filepath.Join(root, "init.lua"))
				return root
			},
			mention: "nothing for Neovim to load",
		},
		{
			name: "no components",
			break_: func(t *testing.T, root string) string {
				remove(t, filepath.Join(root, "components"))
				return root
			},
			mention: "no component contract",
		},
		{
			// A tree without a lockfile installs whatever the plugin branches
			// point at today, which is the reproducibility this project keeps a
			// lockfile for.
			name: "no lazy-lock.json",
			break_: func(t *testing.T, root string) string {
				remove(t, filepath.Join(root, "lazy-lock.json"))
				return root
			},
			mention: "would not be pinned",
		},
		{
			// A release that predates the bootstrap entrypoint cannot be
			// installed by a CLI that drives it, and the place to say so is
			// before anything has been moved.
			name: "no bootstrap entrypoint",
			break_: func(t *testing.T, root string) string {
				remove(t, filepath.Join(root, "lua", "chroma", "bootstrap.lua"))
				return root
			},
			mention: "no way to bootstrap it",
		},
		{
			name: "a component that does not read",
			break_: func(t *testing.T, root string) string {
				write(t, filepath.Join(root, "components", "broken.json"), "{ not json\n")
				return root
			},
			mention: "does not read",
		},
		{
			name: "a contract that does not resolve",
			break_: func(t *testing.T, root string) string {
				write(t, filepath.Join(root, "components", "orphan.json"),
					`{"contract": 5, "id": "orphan", "requires": ["nothing"]}`+"\n")
				return root
			},
			mention: "does not resolve",
		},
		{
			// Everything requires core, so a contract without it is one nothing
			// can be built from — the same refusal the editor makes.
			name: "no core",
			break_: func(t *testing.T, root string) string {
				remove(t, filepath.Join(root, "components", "core.json"))
				remove(t, filepath.Join(root, "components", "terraform.json"))
				write(t, filepath.Join(root, "components", "lonely.json"),
					`{"contract": 5, "id": "lonely"}`+"\n")
				return root
			},
			mention: `declares no "core"`,
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := tc.break_(t, tree(t))

			prepared, err := LocalSource{Root: root}.Prepare(context.Background())
			if err == nil {
				t.Fatalf("prepared %q instead of refusing", prepared.Root)
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to mention %q", err, tc.mention)
			}
		})
	}
}

func remove(t *testing.T, path string) {
	t.Helper()
	if err := os.RemoveAll(path); err != nil {
		t.Fatalf("removing %s: %v", path, err)
	}
}

// The developer case this exists for: on the machine this was written on, the
// checkout *is* the configuration directory, by symlink.
func TestSourceInsideTargetIsRefused(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	if err := os.MkdirAll(paths.ConfigDir, 0o755); err != nil {
		t.Fatalf("creating the target: %v", err)
	}

	for _, tc := range []struct {
		name    string
		source  string
		mention string
	}{
		{"the target itself", paths.ConfigDir, "are both"},
		{"a directory inside the target", filepath.Join(paths.ConfigDir, "nested"), "is inside"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if err := os.MkdirAll(tc.source, 0o755); err != nil {
				t.Fatalf("creating the source: %v", err)
			}
			err := RefuseSourceInsideTarget(tc.source, paths)
			if err == nil {
				t.Fatal("accepted a source inside the target")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to say %q", err, tc.mention)
			}
		})
	}
}

// Following symlinks is the point: a checkout symlinked as the configuration is
// the same directory by any measure that matters to a rename.
func TestSourceSymlinkedAsTargetIsRefused(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	checkout := filepath.Join(root, "checkout")
	if err := os.MkdirAll(checkout, 0o755); err != nil {
		t.Fatalf("creating the checkout: %v", err)
	}
	if err := os.MkdirAll(filepath.Dir(paths.ConfigDir), 0o755); err != nil {
		t.Fatalf("creating the config root: %v", err)
	}
	if err := os.Symlink(checkout, paths.ConfigDir); err != nil {
		t.Skipf("this filesystem will not take a symlink: %v", err)
	}

	if err := RefuseSourceInsideTarget(checkout, paths); err == nil {
		t.Error("accepted a source that is the target through a symlink")
	}
}

// And an ordinary developer layout is allowed, or the check above would be a
// refusal of everything.
func TestSourceBesideTheTargetIsAccepted(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	checkout := filepath.Join(root, "Projects", "chroma-nvim")
	if err := os.MkdirAll(checkout, 0o755); err != nil {
		t.Fatalf("creating the checkout: %v", err)
	}
	if err := RefuseSourceInsideTarget(checkout, paths); err != nil {
		t.Errorf("refused an ordinary developer layout: %v", err)
	}
}
