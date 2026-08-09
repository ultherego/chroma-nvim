// Package install places a Chroma Neovim release on a machine.
//
// This file is the part everything else measures against: where the
// configuration goes, where its data and state go, and where the selection
// already lives. Every mutating command resolves paths through here, because a
// path assembled twice is a path that will eventually be assembled differently
// — and the two places that would disagree are "what the installer wrote" and
// "what the uninstaller deletes".
package install

import (
	"fmt"
	"os"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/state"
)

// AppName is the default NVIM_APPNAME: an installation of its own, beside
// whatever else is in ~/.config, rather than on top of it.
const AppName = "chroma-nvim"

// DefaultAppName is what `--default` means: Neovim's own directory, taken over
// only after the existing configuration has been backed up.
const DefaultAppName = "nvim"

// Paths is everywhere one installation touches.
type Paths struct {
	// AppName is what NVIM_APPNAME has to be to run this installation. Empty
	// for the default installation, because Neovim needs no variable to find
	// its own directory — and an empty string here is a fact, not a missing
	// value, so it is what the bootstrap step passes through.
	AppName string

	ConfigDir string // the release tree: init.lua, lua/, components/
	DataDir   string // plugins, parsers, Mason
	StateDir  string // install state and logs

	// SelectionFile is the user's component selection, and it is deliberately
	// not under AppName. It belongs to the person rather than to a release, and
	// an update replaces ConfigDir wholesale. It comes from internal/state so
	// that the CLI and the editor cannot disagree about where it is.
	//
	// One consequence, written down rather than discovered: two installations
	// with different appnames share this file. See "Open decisions" in
	// cli/DESIGN.md.
	SelectionFile string

	// InstallState describes the deployment that was actually carried out, and
	// is written only after it has been verified.
	InstallState string

	// BackupDir is the directory a backup is made *in*, not a directory of
	// backups: the existing configuration is renamed to a sibling of itself, so
	// that the move cannot cross a filesystem and cannot half-succeed. It is
	// therefore the parent of ConfigDir.
	BackupDir string

	// LogDir holds one file per mutating operation. See cli/DESIGN.md.
	LogDir string
}

// ResolvePaths works out where an installation goes, or refuses.
//
// It refuses rather than guessing. Every one of these directories is somewhere
// files will be created, moved and eventually deleted, and a relative path
// resolves against whatever directory the CLI happened to be started in — which
// is not a worse answer than the right one, it is a different machine-visible
// location that no editor will ever read.
func ResolvePaths(useDefault bool) (Paths, error) {
	appName := AppName
	if useDefault {
		appName = DefaultAppName
	}

	config, err := baseDir("XDG_CONFIG_HOME", ".config")
	if err != nil {
		return Paths{}, err
	}
	data, err := baseDir("XDG_DATA_HOME", filepath.Join(".local", "share"))
	if err != nil {
		return Paths{}, err
	}
	stateBase, err := baseDir("XDG_STATE_HOME", filepath.Join(".local", "state"))
	if err != nil {
		return Paths{}, err
	}

	selection, err := state.Path()
	if err != nil {
		return Paths{}, fmt.Errorf("locating the component selection: %w", err)
	}

	paths := Paths{
		ConfigDir:     filepath.Join(config, appName),
		DataDir:       filepath.Join(data, appName),
		StateDir:      filepath.Join(stateBase, appName),
		SelectionFile: selection,
	}
	paths.InstallState = filepath.Join(paths.StateDir, "install.json")
	paths.BackupDir = filepath.Dir(paths.ConfigDir)
	paths.LogDir = filepath.Join(paths.StateDir, "logs")

	// The default installation is the one Neovim finds without being told.
	if !useDefault {
		paths.AppName = appName
	}

	return paths, nil
}

// baseDir resolves one XDG variable, or the documented fallback under the home
// directory.
func baseDir(variable, fallback string) (string, error) {
	if set := os.Getenv(variable); set != "" {
		if !filepath.IsAbs(set) {
			return "", fmt.Errorf("%s is %q, which is not an absolute path", variable, set)
		}
		return filepath.Clean(set), nil
	}

	home, err := os.UserHomeDir()
	if err != nil {
		return "", fmt.Errorf("%s is unset and there is no home directory to fall back on: %w", variable, err)
	}
	if !filepath.IsAbs(home) {
		return "", fmt.Errorf("the home directory is %q, which is not an absolute path", home)
	}

	return filepath.Join(home, fallback), nil
}
