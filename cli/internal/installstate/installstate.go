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
//
// 5 replaced `handed_back` with `handover`, a state rather than a flag. H4
// forged the old inference: with Chroma still installed, deleting the backup and
// one file out of the tree was enough to make it conclude the user's
// configuration had been given back. The weakness was that the conclusion came
// from what the directory looked like, and "this no longer looks like a complete
// Chroma tree" is not "this is exactly what we were holding for you".
//
// So the handover is a protocol now, and `pending` is written before the first
// move rather than inferred after it. Nothing about giving somebody's data back
// begins until the intention to do it is on disk. A flag pair would have left
// `pending && handed_back` expressible and meaningless; a state cannot say two
// things at once.
//
// 4 added `handed_back`, and it exists because clearing `user_backup` was not
// enough. An uninstall that restored somebody's configuration and then stopped
// left a record saying nothing was pending — and the next run treated the
// directory as Chroma's, moved it aside and deleted it. Measured, by a fault
// point, on somebody's own files. The record has to say not just "there is
// nothing to give back" but "it has already been given".
//
// 3 added `user_backup` and `cache_dir`, and the first of those closes a hole
// this document had from the start. `backup` means "what was moved aside", and
// that was two different things wearing one name: the configuration somebody
// already had, moved out of the way by `--default`, and a Chroma generation
// moved aside by an update. After one update the second overwrote the first,
// so the path to the user's own configuration was no longer recorded anywhere
// — and `uninstall` could not give back the thing it had taken.
//
// 2 added `previous`. An installation is a generation rather than a state of
// affairs: `update` moves the current one aside and records what it replaced,
// so that `rollback` has something to go back to and so that a person can be
// told what they are on and what they were on. Schema 1 could say what was
// moved aside but not what it was, which is enough to restore a directory and
// not enough to name a version.
const Schema = 5

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

// Handover is where the configuration that was here before Chroma stands.
//
// Only an installation that took a directory over has one. The order is the
// order it happens in, and each step is written down before the move it
// describes rather than after it.
type Handover string

const (
	// HandoverNone: nothing was borrowed. Chroma was installed beside whatever
	// else is on the machine.
	HandoverNone Handover = ""

	// HandoverHeld: Chroma is holding the configuration at UserBackup.
	HandoverHeld Handover = "held"

	// HandoverPending: an uninstall has begun giving it back. Written before
	// anything moves, so that a process which stops existing mid-transfer can be
	// recognised as one — rather than guessed at from what the directories look
	// like afterwards.
	HandoverPending Handover = "pending"

	// HandoverHandedBack: ownership has returned. The directory is not Chroma's
	// to move or remove, now or on any later run.
	HandoverHandedBack Handover = "handed_back"
)

// Generation is an installation that was replaced, and what it was.
//
// Deliberately not a whole State. What rollback needs is where the directory
// went and which release it holds; the rest of a State describes paths that
// have not changed, and copying them would be two records of one fact.
type Generation struct {
	// Version is the release it was, empty for a tree.
	Version string `json:"version,omitempty"`

	// Contract is its component contract version, so a rollback to a
	// generation this CLI no longer understands can be refused rather than
	// carried out.
	Contract int `json:"contract,omitempty"`

	// Path is where it was moved to. This is what rollback restores.
	Path string `json:"path"`

	// InstalledAt is when that generation was itself recorded.
	InstalledAt string `json:"installed_at,omitempty"`

	Source Source `json:"source"`
}

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
	CacheDir      string `json:"cache_dir"`
	SelectionFile string `json:"selection_file"`

	// Backup is what was moved aside, and is empty when there was nothing
	// there. For an update it is the same path as Previous.Path — kept as its
	// own field because it also carries the case Previous cannot: a directory
	// that was not a Chroma installation at all, moved aside by `--default`.
	Backup string `json:"backup,omitempty"`

	// Previous is the Chroma generation this one replaced, and is nil for a
	// first installation. Rollback reads it; nothing else may write it.
	Previous *Generation `json:"previous,omitempty"`

	// UserBackup is the configuration that was here before Chroma, moved aside
	// by `--default` and never touched since. Empty when Chroma was installed
	// beside an existing configuration rather than over one.
	//
	// It is not a generation and must never be treated as one. A generation is
	// something Chroma made and may remove; this is somebody else's work that
	// Chroma borrowed a directory from, and `uninstall` gives it back. Every
	// operation after the first carries this forward unchanged, because losing
	// it would mean losing the only record of what to restore.
	UserBackup string `json:"user_backup,omitempty"`

	// Handover is how far giving that configuration back has got.
	Handover Handover `json:"handover,omitempty"`

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
		{"cache_dir", s.CacheDir},
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

	// The two are different things and must not name one directory. If they
	// did, removing the generation would take the user's configuration with it.
	// A path to hold and a state that says nothing is held are two halves of
	// different records.
	switch s.Handover {
	case HandoverNone, HandoverHandedBack:
		if s.UserBackup != "" {
			return fmt.Errorf("records handover %q and a configuration at %s to restore", s.Handover, s.UserBackup)
		}
	case HandoverHeld, HandoverPending:
		if s.UserBackup == "" {
			return fmt.Errorf("records handover %q and no configuration to restore", s.Handover)
		}
	default:
		return fmt.Errorf("records an unknown handover state %q", s.Handover)
	}

	// No two of these may name one directory, and neither may name the
	// installation itself. Every alias sends a destructive step at the wrong
	// object: removing the generation would take the user's configuration with
	// it, and restoring either over the target would be Chroma moving a
	// directory onto itself.
	for _, pair := range []struct {
		first, second, names string
	}{
		{s.UserBackup, previousPath(s), "the user's own configuration and a Chroma generation"},
		{s.UserBackup, s.ConfigDir, "the user's own configuration and the installation"},
		{previousPath(s), s.ConfigDir, "a Chroma generation and the installation"},
	} {
		if pair.first != "" && pair.first == pair.second {
			return fmt.Errorf("records %s at the same path %s", pair.names, pair.first)
		}
	}

	if s.Previous != nil {
		// A generation that does not say where it went is a generation rollback
		// cannot restore, which makes recording it worse than not recording it:
		// it promises a way back that is not there.
		if s.Previous.Path == "" {
			return errors.New("records a previous generation with no path")
		}
		switch s.Previous.Source.Type {
		case FromRelease, FromTree:
		default:
			return fmt.Errorf("records a previous generation with an unknown source type %q", s.Previous.Source.Type)
		}
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

// previousPath is where the previous generation is, or "" when there is none.
func previousPath(s State) string {
	if s.Previous == nil {
		return ""
	}
	return s.Previous.Path
}
