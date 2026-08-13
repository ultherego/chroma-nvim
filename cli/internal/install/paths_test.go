package install

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// xdg confines a test to a directory of its own — every variable, not the ones a
// particular test happens to read. `XDG_CACHE_HOME` was missing once, so the
// package resolved CacheDir to the real `~/.cache/nvim` of whoever ran it, and
// the suite was quietly deleting the Neovim cache of its own author.
//
// HOME is set too, because each of these has a documented fallback under it, and
// XDG_RUNTIME_DIR because the lock lives there. A test harness that can reach
// outside its own root proves nothing about destructive code.
func xdg(t *testing.T, root string) {
	t.Helper()

	t.Setenv("HOME", root)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(root, "data"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))
	t.Setenv("XDG_CACHE_HOME", filepath.Join(root, "cache"))
	t.Setenv("XDG_RUNTIME_DIR", filepath.Join(root, "run"))

	if err := os.MkdirAll(filepath.Join(root, "run"), 0o700); err != nil {
		t.Fatal(err)
	}

	// Checked here, so that no fixture has to remember to. Both shapes, because
	// `--default` and an installation of its own resolve different directories
	// and a harness that confines one of them confines nothing.
	for _, useDefault := range []bool{false, true} {
		paths, err := ResolvePaths(useDefault)
		if err != nil {
			t.Fatalf("ResolvePaths(%v): %v", useDefault, err)
		}
		confined(t, root, paths)
	}
}

// confined refuses to let a destructive test run against anything outside its
// own root.
//
// Called by xdg rather than by the fixtures, so that adding a fixture cannot
// silently opt out of it. The cost of getting this wrong is not a failing test
// — it is a passing one, run against the machine of whoever ran it, which is
// the kind of false confidence worth spending a function on.
func confined(t *testing.T, root string, paths Paths) {
	t.Helper()

	clean := filepath.Clean(root) + string(filepath.Separator)
	for name, path := range map[string]string{
		"ConfigDir":     paths.ConfigDir,
		"DataDir":       paths.DataDir,
		"StateDir":      paths.StateDir,
		"CacheDir":      paths.CacheDir,
		"SelectionFile": paths.SelectionFile,
		"InstallState":  paths.InstallState,
		"BackupDir":     paths.BackupDir,
		"LogDir":        paths.LogDir,
	} {
		if path == "" {
			continue
		}
		if !strings.HasPrefix(filepath.Clean(path)+string(filepath.Separator), clean) {
			t.Fatalf("%s resolved to %s, which is outside the test root %s: this test would have run against the machine it is running on", name, path, root)
		}
	}
}

// The harness proves its own confinement, because nothing else does.
//
// Each variable governs one directory, and leaving any of them unset sends that
// directory to the home of whoever is running the suite. That is exactly what
// happened with XDG_CACHE_HOME, for as long as nothing in the suite moved the
// cache directory rather than removing it.
func TestEveryBaseDirectoryVariableIsWhatConfinesIt(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	for variable, governs := range map[string]func(Paths) string{
		"XDG_CONFIG_HOME": func(p Paths) string { return p.ConfigDir },
		"XDG_DATA_HOME":   func(p Paths) string { return p.DataDir },
		"XDG_STATE_HOME":  func(p Paths) string { return p.StateDir },
		"XDG_CACHE_HOME":  func(p Paths) string { return p.CacheDir },
	} {
		t.Run("without "+variable, func(t *testing.T) {
			t.Setenv(variable, "")
			t.Setenv("HOME", t.TempDir())

			paths, err := ResolvePaths(true)
			if err != nil {
				t.Fatalf("ResolvePaths: %v", err)
			}

			inside := filepath.Clean(root) + string(filepath.Separator)
			if strings.HasPrefix(filepath.Clean(governs(paths))+string(filepath.Separator), inside) {
				t.Errorf("%s unset left its directory inside the root anyway, so confinement does not depend on it", variable)
			}
		})
	}
}

func TestIsolatedInstallationIsBesideTheRest(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	if paths.AppName != AppName {
		t.Errorf("AppName = %q, want %q", paths.AppName, AppName)
	}
	for _, tc := range []struct{ got, want string }{
		{paths.ConfigDir, filepath.Join(root, "config", AppName)},
		{paths.DataDir, filepath.Join(root, "data", AppName)},
		{paths.StateDir, filepath.Join(root, "state", AppName)},
		{paths.InstallState, filepath.Join(root, "state", AppName, "install.json")},
		{paths.LogDir, filepath.Join(root, "state", AppName, "logs")},
	} {
		if tc.got != tc.want {
			t.Errorf("got %q, want %q", tc.got, tc.want)
		}
	}
}

// The backup is a rename to a sibling, so the directory it happens in has to be
// the parent of the target — anything else can cross a filesystem, and a backup
// that half-succeeds is the one failure this whole design exists to prevent.
func TestBackupHappensBesideTheTarget(t *testing.T) {
	xdg(t, t.TempDir())

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	if paths.BackupDir != filepath.Dir(paths.ConfigDir) {
		t.Errorf("BackupDir = %q, want the parent of %q", paths.BackupDir, paths.ConfigDir)
	}
}

// --default is Neovim's own directory, and it needs no NVIM_APPNAME to be
// found. The empty string is the answer, not a missing one.
func TestDefaultInstallationTakesNeovimsOwnDirectory(t *testing.T) {
	root := t.TempDir()
	xdg(t, root)

	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	if paths.AppName != "" {
		t.Errorf("AppName = %q, want empty for the default installation", paths.AppName)
	}
	if paths.ConfigDir != filepath.Join(root, "config", DefaultAppName) {
		t.Errorf("ConfigDir = %q", paths.ConfigDir)
	}
	if paths.StateDir != filepath.Join(root, "state", DefaultAppName) {
		t.Errorf("StateDir = %q", paths.StateDir)
	}
}

// The two installations are separate everywhere except the one document that
// belongs to the person rather than the release.
func TestTheTwoInstallationsShareOnlyTheSelection(t *testing.T) {
	xdg(t, t.TempDir())

	isolated, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	def, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	if isolated.SelectionFile != def.SelectionFile {
		t.Errorf("selection differs between installations: %q and %q", isolated.SelectionFile, def.SelectionFile)
	}
	for _, pair := range [][2]string{
		{isolated.ConfigDir, def.ConfigDir},
		{isolated.DataDir, def.DataDir},
		{isolated.StateDir, def.StateDir},
		{isolated.InstallState, def.InstallState},
	} {
		if pair[0] == pair[1] {
			t.Errorf("two installations resolved to the same path: %q", pair[0])
		}
	}
}

// One definition of where the selection is, shared with the editor through
// internal/state. A second one here would be free to drift.
func TestSelectionComesFromTheStatePackage(t *testing.T) {
	xdg(t, t.TempDir())

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	want, err := state.Path()
	if err != nil {
		t.Fatalf("state.Path: %v", err)
	}
	if paths.SelectionFile != want {
		t.Errorf("SelectionFile = %q, want %q", paths.SelectionFile, want)
	}
}

func TestXDGFallsBackToTheHomeDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_CONFIG_HOME", "")
	t.Setenv("XDG_DATA_HOME", "")
	t.Setenv("XDG_STATE_HOME", "")

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}

	for _, tc := range []struct{ got, want string }{
		{paths.ConfigDir, filepath.Join(home, ".config", AppName)},
		{paths.DataDir, filepath.Join(home, ".local", "share", AppName)},
		{paths.StateDir, filepath.Join(home, ".local", "state", AppName)},
	} {
		if tc.got != tc.want {
			t.Errorf("got %q, want %q", tc.got, tc.want)
		}
	}
}

// Refusing beats guessing: these are directories things get created in, moved
// to and eventually deleted from.
func TestRefusesWhenNoAbsolutePathCanBeResolved(t *testing.T) {
	for _, tc := range []struct {
		name    string
		env     map[string]string
		mention string
	}{
		{
			name:    "a relative XDG_CONFIG_HOME",
			env:     map[string]string{"XDG_CONFIG_HOME": "relative/config"},
			mention: "XDG_CONFIG_HOME",
		},
		{
			name:    "a relative XDG_DATA_HOME",
			env:     map[string]string{"XDG_DATA_HOME": "relative/data"},
			mention: "XDG_DATA_HOME",
		},
		{
			name:    "a relative XDG_STATE_HOME",
			env:     map[string]string{"XDG_STATE_HOME": "relative/state"},
			mention: "XDG_STATE_HOME",
		},
		{
			// No variable to read and no home to fall back on. The XDG entries
			// have to be cleared as well, or this passes on the fallback that is
			// exactly what it claims to be testing the absence of.
			name: "nothing at all",
			env: map[string]string{
				"HOME":            "",
				"XDG_CONFIG_HOME": "",
				"XDG_DATA_HOME":   "",
				"XDG_STATE_HOME":  "",
			},
			mention: "home directory",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			xdg(t, t.TempDir())
			for name, value := range tc.env {
				t.Setenv(name, value)
			}

			paths, err := ResolvePaths(false)
			if err == nil {
				t.Fatalf("resolved %q instead of refusing", paths.ConfigDir)
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to name %s", err, tc.mention)
			}
		})
	}
}
