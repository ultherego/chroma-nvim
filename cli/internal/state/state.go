// Package state reads and writes what the user chose.
//
// This is not the component contract. That describes the product — what a
// component is and what it needs — and lives with the release. This describes
// one person's intent, lives in their configuration directory, and survives a
// release being replaced.
//
// The rules here must match lua/chroma/state.lua. Both are driven by the same
// fixtures in tests/fixtures/component-state, so a disagreement is a failing
// test rather than a machine behaving differently from its editor.
package state

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"

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
// not inside the release tree, which is replaced wholesale by an update.
//
// It fails rather than guessing. With no XDG_CONFIG_HOME and no home directory
// there is no answer, and the relative path this used to return —
// `.config/chroma/components.json` — is not a worse answer, it is a different
// file: one under whatever directory the CLI happened to be run from, which the
// editor would never read and the user would never find.
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

// Load reads the selection and checks it against the components that exist.
//
// A file that is not there is not an error and not an empty selection: it is a
// configuration that predates any of this, and everything is enabled. An
// upgrade must not silently switch off the Terraform support somebody has been
// using. `found` distinguishes the two.
func Load(path string, set component.Set) (state State, found bool, err error) {
	contents, err := os.ReadFile(path)
	if os.IsNotExist(err) {
		return State{Schema: Schema}, false, nil
	}
	if err != nil {
		return State{}, false, fmt.Errorf("reading %s: %w", path, err)
	}

	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&state); err != nil {
		return State{}, true, fmt.Errorf("%s: %w", path, err)
	}

	// Decode reads the next value in what it treats as a stream, so a file
	// holding two documents parses as the first one and says nothing about the
	// second. A selection is one document; the same rule as the component
	// reader, and the same rule Lua's decoder applies on its own.
	if decoder.More() {
		return State{}, true, fmt.Errorf("%s: has more than one document in it", path)
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

// Write replaces the file atomically. Not because this one is precious, but
// because it will be read at startup by an editor that decides what to load
// from it, and a half-written selection is a Chroma that comes up wrong.
//
// It refuses to write a selection this package would refuse to read. `set` is
// the contract to check against, and it is required rather than optional: the
// caller is a TUI, and a TUI is a thing people will change. Leaving the
// invariants to it would mean the one guarantee that matters here — that a file
// this wrote can be read back — held only as long as every future caller
// remembered. Writing `core`, a duplicate or a component that does not exist
// produces a file the next startup drops into safe mode over, which is a
// perfectly avoidable way to switch somebody's editor off.
func Write(path string, state State, set component.Set) error {
	state.Schema = Schema
	sort.Strings(state.Selected)
	if state.Selected == nil {
		state.Selected = []string{}
	}

	if err := state.validate(set); err != nil {
		return fmt.Errorf("refusing to write %s: %w", path, err)
	}

	contents, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return fmt.Errorf("encoding the selection: %w", err)
	}
	contents = append(contents, '\n')

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}

	// In the same directory, so the rename below cannot cross a filesystem.
	temporary, err := os.CreateTemp(dir, ".components.*.json")
	if err != nil {
		return fmt.Errorf("creating a temporary file in %s: %w", dir, err)
	}
	name := temporary.Name()

	abandon := func(cause error) error {
		temporary.Close()
		os.Remove(name)
		return cause
	}

	if _, err := temporary.Write(contents); err != nil {
		return abandon(fmt.Errorf("writing %s: %w", name, err))
	}
	// Or the rename can land before the bytes, leaving an empty selection where
	// a real one was.
	if err := temporary.Sync(); err != nil {
		return abandon(fmt.Errorf("syncing %s: %w", name, err))
	}
	if err := temporary.Close(); err != nil {
		return abandon(fmt.Errorf("closing %s: %w", name, err))
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return abandon(fmt.Errorf("setting the mode of %s: %w", name, err))
	}
	if err := os.Rename(name, path); err != nil {
		return abandon(fmt.Errorf("replacing %s: %w", path, err))
	}

	// The rename is atomic but not yet durable: the directory entry it changed
	// is not on the disk until the directory itself is flushed.
	//
	// Both failures were swallowed here, which made this paragraph and the one
	// in DESIGN.md describe something the code did not do. A write that reports
	// success without the entry reaching the disk is exactly the case fsync is
	// for — the machine loses power, and the selection is either the old one or
	// nothing.
	handle, err := os.Open(dir)
	if err != nil {
		return fmt.Errorf("opening %s to flush it: %w", dir, err)
	}
	if err := handle.Sync(); err != nil {
		handle.Close()
		return fmt.Errorf("flushing %s: %w", dir, err)
	}
	if err := handle.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", dir, err)
	}

	return nil
}
