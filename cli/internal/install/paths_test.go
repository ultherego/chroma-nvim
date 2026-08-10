package install

import (
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// xdg points every base directory at one root, which is what the tests want and
// also what CI does: no case here may resolve to a real home directory.
func xdg(t *testing.T, root string) {
	t.Helper()
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	t.Setenv("XDG_DATA_HOME", filepath.Join(root, "data"))
	t.Setenv("XDG_STATE_HOME", filepath.Join(root, "state"))

	// The fourth, and it was missing. Without it every test in this package
	// resolved CacheDir to the real `~/.cache/nvim` of whoever ran them — and
	// an uninstall removes the cache directory, so the suite was quietly
	// deleting the Neovim cache of its own author. Found by a takeover test
	// that moves the directory aside instead of removing it, which is the only
	// reason it was visible at all.
	t.Setenv("XDG_CACHE_HOME", filepath.Join(root, "cache"))
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
