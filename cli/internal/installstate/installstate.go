// Package installstate records the deployment that was actually carried out:
// which release, in which directories, when, and what was moved aside to make
// room. Written by the installer, read by update, rollback and uninstall, so
// none of those has to work out where things are from its environment.
//
// Not the component selection, which is what a person wants and outlives
// releases being replaced over it. Its schema is its own for the same reason.
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

// Schema is the version of this document. The history and the measurements
// behind it are in cli/DESIGN.md; what each version changed, in one line:
//
//	6  borrowing became plural, and each borrowed directory got an identity:
//	   taking over ~/.config/nvim takes over four directories, and schema 5
//	   recorded one — so an uninstall removed the other three as Chroma's.
//	5  handover became a state rather than a flag, written before the move,
//	   because H4 forged an inference drawn from what a directory looked like.
//	4  handed_back, because clearing user_backup could not say "already given":
//	   the next run treated the directory as Chroma's and deleted it.
//	3  user_backup and cache_dir; `backup` had been two things under one name,
//	   and after one update the path to the user's own configuration was gone.
//	2  previous, so rollback has something to go back to and a person can be
//	   told what they are on.
const Schema = 6

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

// Handover is where the configuration that was here before Chroma stands. Only
// an installation that took a directory over has one, and each step is written
// down before the move it describes.
type Handover string

const (
	// HandoverNone: nothing was borrowed. Chroma was installed beside whatever
	// else is on the machine.
	HandoverNone Handover = ""

	// HandoverHeld: Chroma is holding the configuration at UserBackup.
	HandoverHeld Handover = "held"

	// HandoverPending: an uninstall has begun giving it back. Written before
	// anything moves, so a process that stops mid-transfer can be recognised as
	// one rather than guessed at afterwards.
	HandoverPending Handover = "pending"

	// HandoverHandedBack: ownership has returned. The directory is not Chroma's
	// to move or remove, now or on any later run.
	HandoverHandedBack Handover = "handed_back"
)

// Borrowed is one directory Chroma took over and owes back.
type Borrowed struct {
	// Kind is which of Neovim's directories this is: config, data, state or
	// cache. Recorded so a report can name it in words somebody recognises.
	Kind string `json:"kind"`

	// Original is where it belongs, and Backup is where Chroma moved it.
	Original string `json:"original"`
	Backup   string `json:"backup"`

	// Device, Inode and Mtime are what it was when it was moved. A rename keeps
	// all three, so together they prove that what is at Backup now is what was
	// taken. Mtime is not decoration: on ext4 a directory created where one was
	// just deleted gets the same inode every time, measured 40 out of 40. See
	// cli/DESIGN.md, "One handover state per directory".
	//
	// Not a defence against the owner of the account rewriting this file.
	Device uint64 `json:"device"`
	Inode  uint64 `json:"inode"`
	Mtime  int64  `json:"mtime"`

	// Handover is how far giving this one back has got. Per directory, because
	// a process can stop after returning two of three.
	Handover Handover `json:"handover"`
}

// Generation is an installation that was replaced, and what it was. Not a whole
// State: rollback needs where the directory went and which release it holds,
// and the rest would be two records of one fact.
type Generation struct {
	// Version is the release it was, empty for a tree.
	Version string `json:"version,omitempty"`

	// Contract is its component contract version, so a rollback to a
	// generation this CLI no longer understands can be refused rather than
	// carried out.
	Contract int `json:"contract,omitempty"`

	// Path is where it was moved to. This is what rollback restores.
	Path string `json:"path"`

	// Device, Inode and Mtime are what that directory was when it was moved
	// aside: a path says where to look, these say whether what is there is the
	// generation Chroma kept. Measured before they existed: an ordinary
	// Chroma-shaped directory at that path was restored as the release it was not.
	Device uint64 `json:"device,omitempty"`
	Inode  uint64 `json:"inode,omitempty"`
	Mtime  int64  `json:"mtime,omitempty"`

	// InstalledAt is when that generation was itself recorded.
	InstalledAt string `json:"installed_at,omitempty"`

	Source Source `json:"source"`
}

// State is one installation, as it was carried out.
type State struct {
	Schema int `json:"schema"`

	// Version is the release. Empty means a tree installation, which update
	// needs to know and cannot infer from Source.
	Version string `json:"version"`

	// Contract is the component contract version of the tree that was installed,
	// so a CLI that no longer understands it can refuse without reading the
	// tree first.
	Contract int `json:"contract"`

	// AppName is what NVIM_APPNAME has to be, and is empty for the installation
	// that took over Neovim's own directory.
	AppName string `json:"appname"`

	ConfigDir     string `json:"config_dir"`
	DataDir       string `json:"data_dir"`
	StateDir      string `json:"state_dir"`
	CacheDir      string `json:"cache_dir"`
	SelectionFile string `json:"selection_file"`

	// Backup is what was moved aside, empty when there was nothing there. For an
	// update it is Previous.Path; its own field because it also carries what
	// Previous cannot — a directory that was never a Chroma installation.
	Backup string `json:"backup,omitempty"`

	// Previous is the Chroma generation this one replaced, and is nil for a
	// first installation. Rollback reads it; nothing else may write it.
	Previous *Generation `json:"previous,omitempty"`

	// Borrowed are the directories that existed before Chroma and were moved
	// aside for it. None is a generation: a generation is something Chroma made
	// and may remove, these are somebody else's work. Every operation after the
	// first carries the list forward unchanged.
	Borrowed []Borrowed `json:"borrowed,omitempty"`

	// InstalledAt is when this was recorded, which is after it was verified.
	InstalledAt string `json:"installed_at"`

	Source Source `json:"source"`
}

// Path returns where the state for an installation lives. Kept as an argument
// rather than worked out here, because install.Paths already owns that answer
// and two answers is one too many.

// Load reads the state of a managed installation. A file that is not there is
// not an error — it means this is not a managed installation, which `install`
// finds and `update` refuses. `found` tells the two apart.
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

	// Every one of these is a path something later acts on, and a record that
	// does not say where it is cannot be acted on safely.
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

	// The two must not name one directory: removing the generation would take
	// the user's configuration with it. Each borrowed directory has to say all
	// of what it is, or none of it can be acted on.
	kinds := map[string]bool{}
	for _, borrowed := range s.Borrowed {
		switch borrowed.Handover {
		case HandoverHeld, HandoverPending, HandoverHandedBack:
		default:
			return fmt.Errorf("records an unknown handover state %q for %s", borrowed.Handover, borrowed.Kind)
		}
		if borrowed.Kind == "" || borrowed.Original == "" || borrowed.Backup == "" {
			return fmt.Errorf("records a borrowed directory that does not say what it is: %+v", borrowed)
		}
		if borrowed.Handover != HandoverHandedBack && borrowed.Device == 0 && borrowed.Inode == 0 && borrowed.Mtime == 0 {
			return fmt.Errorf("records %s at %s with no identity, so it could not be shown to be the one taken", borrowed.Kind, borrowed.Backup)
		}
		if kinds[borrowed.Kind] {
			return fmt.Errorf("records %s as borrowed twice", borrowed.Kind)
		}
		kinds[borrowed.Kind] = true

		// Two directories cannot be in one place, so whichever entry was acted
		// on second would move what the first had just put there.
		for _, other := range s.Borrowed {
			if other.Kind == borrowed.Kind {
				continue
			}
			if other.Backup == borrowed.Backup {
				return fmt.Errorf("records your %s and your %s as both held at %s", borrowed.Kind, other.Kind, borrowed.Backup)
			}
			if other.Original == borrowed.Original {
				return fmt.Errorf("records your %s and your %s as both belonging at %s", borrowed.Kind, other.Kind, borrowed.Original)
			}
		}
		if borrowed.Original == borrowed.Backup {
			return fmt.Errorf("records %s as borrowed from and to the same path %s", borrowed.Kind, borrowed.Original)
		}
	}

	// No two of these may name one directory, and neither may name the
	// installation itself: every alias sends a destructive step at the wrong
	// object.
	pairs := []struct {
		first, second, names string
	}{
		{previousPath(s), s.ConfigDir, "a Chroma generation and the installation"},
	}
	for _, borrowed := range s.Borrowed {
		pairs = append(pairs,
			struct{ first, second, names string }{borrowed.Backup, previousPath(s), "your " + borrowed.Kind + " and a Chroma generation"},
			struct{ first, second, names string }{borrowed.Backup, s.ConfigDir, "your " + borrowed.Kind + " and the installation"},
			struct{ first, second, names string }{borrowed.Backup, borrowed.Original, "your " + borrowed.Kind + " and where it belongs"},
		)
	}
	for _, pair := range pairs {
		if pair.first != "" && pair.first == pair.second {
			return fmt.Errorf("records %s at the same path %s", pair.names, pair.first)
		}
	}

	if s.Previous != nil {
		// A generation that does not say where it went promises a way back that
		// is not there.
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

// Write records an installation. Called last, and only after verify: a false
// record is an unmanaged directory that update will happily replace, which is
// worse than no record at all.
func Write(path string, state State) (atomicfile.Result, error) {
	state.Schema = Schema

	if err := state.validate(); err != nil {
		return atomicfile.Result{}, fmt.Errorf("refusing to record %s: %w", path, err)
	}

	contents, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return atomicfile.Result{}, fmt.Errorf("encoding the install state: %w", err)
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
