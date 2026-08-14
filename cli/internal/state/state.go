// Package state reads and writes what the user chose: one person's intent, in
// their configuration directory, surviving a release being replaced over it.
// Not the component contract, which describes the product.
//
// The rules must match lua/chroma/state.lua. Both run against the fixtures in
// tests/fixtures/component-state, so a disagreement is a failing test.
package state

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"sort"

	"github.com/ultherego/chroma-nvim/cli/internal/atomicfile"
	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// Schema is the version of this document, and it is deliberately not the
// component contract's. The two describe different things and have no reason to
// move together.
const Schema = 1

// Core is enabled always and is not a choice, so it is never written down.
const Core = "core"

// State is what the user selected. Intent, not status: `selected` says what
// somebody wants Chroma to include, and says nothing about whether the tools it
// needs are installed or new enough. That question belongs to `doctor`.
type State struct {
	Schema   int      `json:"schema"`
	Selected []string `json:"selected"`
}

// Path is where the selection lives: alongside the user's other configuration,
// not inside the release tree, which an update replaces wholesale. It fails
// rather than guessing — the relative path this used to return is not a worse
// answer, it is a different file, under whatever directory the CLI was run from.
func Path() (string, error) {
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("no XDG_CONFIG_HOME and no home directory, so there is nowhere to keep the selection: %w", err)
		}
		config = filepath.Join(home, ".config")
	}
	return filepath.Join(config, "chroma", "components.json"), nil
}

// Load reads the selection and checks it against the components that exist. A
// file that is not there is not an error and not an empty selection: it is a
// configuration that predates any of this, and everything is enabled. `found`
// distinguishes the two.
//
// The question asked first is whether there is an entry here at all, which is
// not the same as whether it can be read. ReadFile follows a link and reports a
// dangling one as ErrNotExist, so a selection somebody made read as a selection
// nobody had ever made — the one answer that means "run everything". Only an
// absent entry means that now; an entry with anything wrong with it is
// reported. Must match lua/chroma/state.lua.
func Load(path string, set component.Set) (state State, found bool, err error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		return State{Schema: Schema}, false, nil
	} else if err != nil {
		return State{}, true, fmt.Errorf("looking at %s: %w", path, err)
	}

	// A symlink to a real file is somebody's own arrangement and is followed.
	target, err := os.Stat(path)
	if err != nil {
		return State{}, true, fmt.Errorf("%s is a link to something that cannot be reached: %w", path, err)
	}
	if !target.Mode().IsRegular() {
		return State{}, true, fmt.Errorf("%s is not a regular file", path)
	}

	contents, err := os.ReadFile(path)
	if err != nil {
		return State{}, true, fmt.Errorf("reading %s: %w", path, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return State{}, true, fmt.Errorf("%s: %w", path, err)
	}

	// Decode reads the next value in what it treats as a stream, so a file holding
	// two documents parses as the first and says nothing about the second. io.EOF
	// rather than More(), for the reason given in component.go.
	var extra json.RawMessage
	switch err := decoder.Decode(&extra); {
	case errors.Is(err, io.EOF):
		// One document, and then the end of it.
	case err == nil:
		return State{}, true, fmt.Errorf("%s: has more than one document in it", path)
	default:
		return State{}, true, fmt.Errorf("%s: has trailing content after the document", path)
	}

	if err := state.validate(set); err != nil {
		return State{}, true, fmt.Errorf("%s: %w", path, err)
	}

	return state, true, nil
}

func (s State) validate(set component.Set) error {
	if s.Schema != Schema {
		return fmt.Errorf("declares schema %d; this understands %d", s.Schema, Schema)
	}

	seen := map[string]bool{}
	for _, id := range s.Selected {
		switch {
		case id == "":
			return fmt.Errorf("selects a component with an empty id")
		case id == Core:
			// Refused rather than ignored: core is not an optional choice, and a
			// file that lists it was written against a different idea of what
			// this document means.
			return fmt.Errorf("selects %q, which is always enabled and is not a choice", Core)
		case seen[id]:
			return fmt.Errorf("selects %q twice", id)
		case set != nil && set[id] == nil:
			// Fail closed. A typo and "a newer CLI wrote this for an older
			// Chroma" look identical here, and both mean the configuration about
			// to run is not the one that was chosen.
			return fmt.Errorf("references unknown component %q", id)
		}
		seen[id] = true
	}

	return nil
}

// Enabled expands a selection into everything that will run, core included, by
// walking the dependency graph now rather than trusting a list written earlier.
// A component whose dependencies change must not be described by a stale copy
// of the graph.
func (s State) Enabled(set component.Set) []string {
	chosen := map[string]bool{}

	var add func(id string)
	add = func(id string) {
		if chosen[id] || set[id] == nil {
			return
		}
		chosen[id] = true
		for _, needed := range set[id].Requires {
			add(needed)
		}
	}

	add(Core)
	for _, id := range s.Selected {
		add(id)
	}

	enabled := make([]string, 0, len(chosen))
	for id := range chosen {
		enabled = append(enabled, id)
	}
	sort.Strings(enabled)
	return enabled
}

// EnabledLegacy is what runs when no selection has ever been written: all of it.
func EnabledLegacy(set component.Set) []string {
	return set.IDs()
}

// Write replaces the file atomically, because it is read at startup by an editor
// that decides what to load from it and a half-written selection is a Chroma
// that comes up wrong.
//
// It refuses to write a selection this package would refuse to read, and `set`
// is required rather than optional: the caller is a TUI, and leaving the
// invariants to it would hold the one guarantee that matters only as long as
// every future caller remembered.
func Write(path string, state State, set component.Set) (atomicfile.Result, error) {
	state.Schema = Schema
	sort.Strings(state.Selected)
	if state.Selected == nil {
		state.Selected = []string{}
	}

	if err := state.validate(set); err != nil {
		return atomicfile.Result{}, fmt.Errorf("refusing to write %s: %w", path, err)
	}

	contents, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return atomicfile.Result{}, fmt.Errorf("encoding the selection: %w", err)
	}

	return replace(path, append(contents, '\n'))
}

// Restore puts back bytes that were already there, without reading them — the
// one case where this package's own validation would be wrong. What an installer
// found is not its to correct, and the alternative is an installer that silently
// rewrites a document it never owned. Everything else about the write is the
// same, which is why it shares the implementation.
func Restore(path string, contents []byte) (atomicfile.Result, error) {
	return replace(path, contents)
}

// replace writes contents to path atomically, or does not write at all. The
// mechanics live in internal/atomicfile, which the install state uses as well:
// the same fifty lines in two packages is the arrangement where one of them
// quietly loses its directory flush.
func replace(path string, contents []byte) (atomicfile.Result, error) {
	return atomicfile.Replace(path, contents, 0o644)
}
