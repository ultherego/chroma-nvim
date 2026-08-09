// Package installstate records the deployment that was actually carried out.
//
// Not the component selection, which is a different document with a different
// lifetime: that one is what a person wants and survives releases being
// replaced over it. This one is what a machine has — which release, in which
// directories, when, and what was moved aside to make room. It is written by
// the installer and read by update, rollback and uninstall, which is the whole
// reason it exists: those three must never have to work out where things are
// from the environment they happen to run in.
//
// Its schema is its own, for the same reason the selection's is: two documents
// with two reasons to change, and tying their numbers together would make one
// of them lie.
package installstate

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/ultherego/chroma-nvim/cli/internal/atomicfile"
)

// Schema is the version of this document.
const Schema = 1

// Source is where an installation came from.
type Source struct {
	// Type is "release" or "tree". A tree is a developer installation, and
	// saying so is what lets update refuse to reason about it.
	Type string `json:"type"`

	// Ref is the tag for a release, or the path for a tree.
	Ref string `json:"ref,omitempty"`

	// SHA256 is the checksum of the archive that was verified before it was
	// unpacked. Empty for a tree, which has no archive.
	SHA256 string `json:"sha256,omitempty"`
}

// Types a source may have.
const (
	FromRelease = "release"
	FromTree    = "tree"
)

// State is one installation, as it was carried out.
type State struct {
	Schema int `json:"schema"`

	// Version is the release. Empty means the installation came from a tree and
	// has no version — which update needs to know, and which is why it is a
	// field rather than something inferred from Source.
	Version string `json:"version"`

	// Contract is the component contract version of the tree that was
	// installed. Recorded because a CLI that no longer understands it must
	// refuse to update this installation, and finding that out should not
	// require reading the installed tree first.
	Contract int `json:"contract"`

	// AppName is what NVIM_APPNAME has to be, and is empty for the installation
	// that took over Neovim's own directory.
	AppName string `json:"appname"`

	ConfigDir     string `json:"config_dir"`
	DataDir       string `json:"data_dir"`
	StateDir      string `json:"state_dir"`
	SelectionFile string `json:"selection_file"`

	// Backup is what was moved aside, and is empty when there was nothing
	// there. It is the only thing rollback has to go on.
	Backup string `json:"backup,omitempty"`

	// InstalledAt is when this was recorded, which is after it was verified.
	InstalledAt string `json:"installed_at"`

	Source Source `json:"source"`
}

// Path returns where the state for an installation lives. Kept as an argument
// rather than worked out here, because install.Paths already owns that answer
// and two answers is one too many.

// Load reads the state of a managed installation.
//
// A file that is not there is not an error: it means this is not a managed
// installation, which is a perfectly ordinary thing for `install` to find and
// the exact thing `update` has to refuse. `found` tells the two apart.
func Load(path string) (state State, found bool, err error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return State{}, false, nil
	}
	if err != nil {
		return State{}, false, fmt.Errorf("reading %s: %w", path, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return State{}, true, fmt.Errorf("%s: %w", path, err)
	}

	// One document per file, asked for the same way the other two readers ask.
	var extra json.RawMessage
	switch err := decoder.Decode(&extra); {
	case errors.Is(err, io.EOF):
	case err == nil:
		return State{}, true, fmt.Errorf("%s: has more than one document in it", path)
	default:
		return State{}, true, fmt.Errorf("%s: has trailing content after the document", path)
	}

	if err := state.validate(); err != nil {
		return State{}, true, fmt.Errorf("%s: %w", path, err)
	}

	return state, true, nil
}

func (s State) validate() error {
	if s.Schema != Schema {
		return fmt.Errorf("declares schema %d; this understands %d", s.Schema, Schema)
	}

	// Every one of these is a path something later will act on — update places
	// over ConfigDir, uninstall deletes what is named here. A record that does
	// not say where it is, is a record that cannot be acted on safely.
	for _, required := range []struct {
		name  string
		value string
	}{
		{"config_dir", s.ConfigDir},
		{"data_dir", s.DataDir},
		{"state_dir", s.StateDir},
		{"selection_file", s.SelectionFile},
		{"installed_at", s.InstalledAt},
	} {
		if required.value == "" {
			return fmt.Errorf("records no %s", required.name)
		}
	}

	switch s.Source.Type {
	case FromRelease, FromTree:
	default:
		return fmt.Errorf("records an unknown source type %q", s.Source.Type)
	}

	return nil
}

// Write records an installation.
//
// Called last, and only after verify. An install state describing something
// that was never checked is worse than none at all: none at all is an
// unmanaged directory, which every command already knows how to refuse, while a
// false one is an unmanaged directory that update will happily replace.
func Write(path string, state State) error {
	state.Schema = Schema

	if err := state.validate(); err != nil {
		return fmt.Errorf("refusing to record %s: %w", path, err)
	}

	contents, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding the install state: %w", err)
	}

	return atomicfile.Replace(path, append(contents, '\n'), 0o644)
}

// Remove deletes the record, for an uninstall. A record that is not there is
// already the state this wants.
func Remove(path string) error {
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("removing %s: %w", path, err)
	}
	return nil
}
