// Package theme is the colourscheme, in two documents that answer two
// questions and belong to two different people.
//
// `themes.json` ships inside a release and says what that release can actually
// draw. `chroma/theme.json` sits with the user's own configuration and says
// which of them they picked — outside the release tree, which an update
// replaces wholesale, exactly like the component selection beside it.
//
// The release is asked first and the user's answer is checked against it. A CLI
// newer than the release it is installing would otherwise offer a colourscheme
// that release has never heard of, and the editor would come up in a different
// one without saying why.
//
// The rules must match lua/chroma/theme.lua. Both run against the fixtures in
// tests/fixtures/theme-choice, so a disagreement is a failing test.
package theme

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"

	"github.com/ultherego/chroma-nvim/cli/internal/atomicfile"
)

// Schema is the version of both documents. They are versioned together because
// neither means anything without the other: the choice names an id, and the
// catalogue is the only thing that says what an id may be.
const Schema = 1

// CatalogueFile is what a release calls its catalogue, at the root of the tree.
// Beside `components/` rather than inside it: a colourscheme is not a component,
// contributes nothing to one, and is chosen once rather than switched on and off.
const CatalogueFile = "themes.json"

// Theme is one colourscheme a release offers.
type Theme struct {
	// ID is what the user's document names, and what `--theme` accepts.
	ID string `json:"id"`

	// Name and Description are what a person is shown when choosing. They come
	// from the release rather than from the CLI, so the two cannot describe the
	// same colourscheme differently.
	Name        string `json:"name"`
	Description string `json:"description"`

	// Colorscheme is the argument to `:colorscheme`, and is not the id. They
	// differ for catppuccin, whose plugin installs four of them under names the
	// flavour is part of — the case that makes a separate field worth having.
	Colorscheme string `json:"colorscheme"`
}

// Catalogue is what a release offers, in the order it offers it. The order is
// the file's and is kept: it decides what a selector shows first, which is a
// presentation decision that belongs to whoever wrote the release.
type Catalogue struct {
	Schema  int     `json:"schema"`
	Default string  `json:"default"`
	Themes  []Theme `json:"themes"`
}

// IDs is every theme this release offers, in the catalogue's own order.
func (c Catalogue) IDs() []string {
	ids := make([]string, 0, len(c.Themes))
	for _, one := range c.Themes {
		ids = append(ids, one.ID)
	}
	return ids
}

// Get finds one theme, and reports whether there is one.
func (c Catalogue) Get(id string) (Theme, bool) {
	for _, one := range c.Themes {
		if one.ID == id {
			return one, true
		}
	}
	return Theme{}, false
}

// Offered says whether this release can draw a colourscheme by that name.
func (c Catalogue) Offered(id string) bool {
	_, found := c.Get(id)
	return found
}

// Choosable says whether there is anything to ask about. A release with one
// theme is not a question, and a release with none predates any of this.
func (c Catalogue) Choosable() bool {
	return len(c.Themes) > 1
}

func (c Catalogue) validate() error {
	if c.Schema != Schema {
		return fmt.Errorf("declares schema %d; this understands %d", c.Schema, Schema)
	}
	if len(c.Themes) == 0 {
		return errors.New("offers no themes at all")
	}

	seen := map[string]bool{}
	for _, one := range c.Themes {
		switch {
		case one.ID == "":
			return errors.New("offers a theme with no id")
		case seen[one.ID]:
			return fmt.Errorf("offers %q twice", one.ID)
		case one.Colorscheme == "":
			// The one field the editor cannot work around. A theme with no
			// name is ugly; a theme with no colourscheme is a `:colorscheme`
			// call with nothing to pass.
			return fmt.Errorf("offers %q without a colorscheme to load", one.ID)
		}
		seen[one.ID] = true
	}

	if c.Default == "" {
		return errors.New("names no default theme")
	}
	if !c.Offered(c.Default) {
		return fmt.Errorf("defaults to %q, which it does not offer", c.Default)
	}

	return nil
}

// LoadCatalogue reads what a release offers, from the root of a prepared tree.
//
// A tree without the file is not an error and not an empty catalogue: it is a
// release from before the colourscheme was a choice. `found` tells them apart,
// and the caller that would otherwise ask a question asks nothing instead.
func LoadCatalogue(root string) (catalogue Catalogue, found bool, err error) {
	return ReadCatalogue(filepath.Join(root, CatalogueFile))
}

// ReadCatalogue is the same, given the file rather than the tree it is in.
// Exported so the shared corpus can be read from where it lives: a test that
// had to build a tree around each fixture would be testing the tree.
func ReadCatalogue(path string) (catalogue Catalogue, found bool, err error) {
	contents, err := os.ReadFile(path)
	if errors.Is(err, fs.ErrNotExist) {
		return Catalogue{}, false, nil
	} else if err != nil {
		return Catalogue{}, true, fmt.Errorf("reading %s: %w", path, err)
	}

	if err := decodeOneDocument(contents, &catalogue); err != nil {
		return Catalogue{}, true, fmt.Errorf("%s: %w", path, err)
	}
	if err := catalogue.validate(); err != nil {
		return Catalogue{}, true, fmt.Errorf("%s: %w", path, err)
	}

	return catalogue, true, nil
}

// Choice is what the user picked. One field, and it is still a document with a
// schema: the alternative is a file holding a bare string, which cannot say
// what it is when something later needs to read it differently.
type Choice struct {
	Schema int    `json:"schema"`
	Theme  string `json:"theme"`
}

// Path is where the choice lives: with the user's own configuration, beside the
// component selection and for the same reason. It fails rather than guessing —
// a relative path here is not a worse answer, it is a different file under
// whatever directory the CLI happened to be run from.
func Path() (string, error) {
	config := os.Getenv("XDG_CONFIG_HOME")
	if config == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", fmt.Errorf("no XDG_CONFIG_HOME and no home directory, so there is nowhere to keep the theme: %w", err)
		}
		config = filepath.Join(home, ".config")
	}
	return filepath.Join(config, "chroma", "theme.json"), nil
}

// Load reads the choice and checks it against what the release offers.
//
// A file that is not there is not an error: it is somebody who never chose, and
// the release's own default applies. `found` distinguishes that from a file
// that is there and unreadable, which is a problem to report rather than a
// licence to pick something on their behalf.
//
// The question asked first is whether there is an entry here at all, which is
// not the same as whether it can be read — ReadFile follows a link and reports a
// dangling one as ErrNotExist, and a choice somebody made would read as a choice
// nobody made. Must match lua/chroma/theme.lua.
func Load(path string, catalogue Catalogue) (choice Choice, found bool, err error) {
	if _, err := os.Lstat(path); errors.Is(err, fs.ErrNotExist) {
		return Choice{Schema: Schema, Theme: catalogue.Default}, false, nil
	} else if err != nil {
		return Choice{}, true, fmt.Errorf("looking at %s: %w", path, err)
	}

	// A symlink to a real file is somebody's own arrangement and is followed.
	target, err := os.Stat(path)
	if err != nil {
		return Choice{}, true, fmt.Errorf("%s is a link to something that cannot be reached: %w", path, err)
	}
	if !target.Mode().IsRegular() {
		return Choice{}, true, fmt.Errorf("%s is not a regular file", path)
	}

	contents, err := os.ReadFile(path)
	if err != nil {
		return Choice{}, true, fmt.Errorf("reading %s: %w", path, err)
	}

	if err := decodeOneDocument(contents, &choice); err != nil {
		return Choice{}, true, fmt.Errorf("%s: %w", path, err)
	}
	if err := choice.validate(catalogue); err != nil {
		return Choice{}, true, fmt.Errorf("%s: %w", path, err)
	}

	return choice, true, nil
}

func (c Choice) validate(catalogue Catalogue) error {
	if c.Schema != Schema {
		return fmt.Errorf("declares schema %d; this understands %d", c.Schema, Schema)
	}
	if c.Theme == "" {
		return errors.New("names no theme")
	}

	// Checked only against a catalogue that was actually read. Nothing to check
	// against is not the same as failing the check, and treating it as failure
	// would refuse every choice made on a machine where the release tree is not
	// in front of this process.
	if len(catalogue.Themes) > 0 && !catalogue.Offered(c.Theme) {
		return fmt.Errorf("names %q, which this release does not offer (%v)", c.Theme, catalogue.IDs())
	}

	return nil
}

// Write replaces the file atomically, because it is read at startup by an editor
// deciding which colourscheme to load, and half a document is an editor that
// comes up in none of them.
//
// It refuses to write what it would refuse to read, and the catalogue is
// required rather than optional for the same reason it is in the selection's
// writer: leaving the invariant to the caller holds it only as long as every
// future caller remembers.
func Write(path string, id string, catalogue Catalogue) (atomicfile.Result, error) {
	choice := Choice{Schema: Schema, Theme: id}
	if err := choice.validate(catalogue); err != nil {
		return atomicfile.Result{}, fmt.Errorf("refusing to write %s: %w", path, err)
	}

	contents, err := json.MarshalIndent(choice, "", "  ")
	if err != nil {
		return atomicfile.Result{}, fmt.Errorf("encoding the theme: %w", err)
	}

	return replace(path, append(contents, '\n'))
}

// Restore puts back bytes that were already there, without reading them — the
// one case where this package's own validation would be wrong. What an installer
// found is not its to correct. Same reasoning, and the same implementation, as
// the selection's Restore.
func Restore(path string, contents []byte) (atomicfile.Result, error) {
	return replace(path, contents)
}

func replace(path string, contents []byte) (atomicfile.Result, error) {
	return atomicfile.Replace(path, contents, 0o644)
}

// decodeOneDocument reads exactly one JSON value and refuses fields it does not
// know. Both are the same rule the component selection is read by: an unknown
// field is a document written against a different idea of what this is, and a
// second document is a file whose second half would be silently ignored.
func decodeOneDocument(contents []byte, into any) error {
	decoder := json.NewDecoder(bytes.NewReader(contents))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(into); err != nil {
		return err
	}

	var extra json.RawMessage
	switch err := decoder.Decode(&extra); {
	case errors.Is(err, io.EOF):
		return nil
	case err == nil:
		return errors.New("has more than one document in it")
	default:
		return errors.New("has trailing content after the document")
	}
}
