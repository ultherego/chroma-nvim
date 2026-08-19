package theme

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fixtures are shared with the Lua reader. Both are driven by the same files so
// that "Go accepts, Lua rejects" is a failing test rather than a machine
// behaving differently from the editor on it.
const fixtures = "../../../tests/fixtures/theme-choice"

// against is the catalogue every choice fixture is checked against, and it is
// one of the fixtures too: a corpus with its own answer written in Go would be
// half a corpus.
func against(t *testing.T) Catalogue {
	t.Helper()

	catalogue, found, err := ReadCatalogue(filepath.Join(fixtures, "catalogue.json"))
	if err != nil || !found {
		t.Fatalf("reading the corpus catalogue: %v (found %v)", err, found)
	}
	return catalogue
}

func corpus(t *testing.T, kind ...string) []string {
	t.Helper()

	dir := filepath.Join(append([]string{fixtures}, kind...)...)
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("reading %s: %v", dir, err)
	}
	if len(entries) == 0 {
		t.Fatalf("%s is empty, which would make this pass for nothing", dir)
	}

	var paths []string
	for _, entry := range entries {
		if !entry.IsDir() {
			paths = append(paths, filepath.Join(dir, entry.Name()))
		}
	}
	return paths
}

func TestValidChoicesLoad(t *testing.T) {
	catalogue := against(t)

	for _, path := range corpus(t, "valid") {
		t.Run(filepath.Base(path), func(t *testing.T) {
			choice, found, err := Load(path, catalogue)
			if err != nil {
				t.Fatalf("Load: %v", err)
			}
			if !found {
				t.Error("found = false for a file that is there")
			}
			if choice.Schema != Schema {
				t.Errorf("schema = %d, want %d", choice.Schema, Schema)
			}
			if !catalogue.Offered(choice.Theme) {
				t.Errorf("loaded %q, which the corpus catalogue does not offer", choice.Theme)
			}
		})
	}
}

func TestInvalidChoicesAreRefused(t *testing.T) {
	catalogue := against(t)

	for _, path := range corpus(t, "invalid") {
		t.Run(filepath.Base(path), func(t *testing.T) {
			choice, found, err := Load(path, catalogue)
			if err == nil {
				t.Fatalf("Load accepted %#v", choice)
			}
			// The file is there, so this is a problem to report rather than
			// somebody who never chose. The difference decides whether the
			// caller falls back to a default or says something is wrong.
			if !found {
				t.Error("found = false for a file that is there and unreadable")
			}
			if !strings.Contains(err.Error(), filepath.Base(path)) {
				t.Errorf("the error does not name the file: %v", err)
			}
		})
	}
}

func TestValidCataloguesLoad(t *testing.T) {
	for _, path := range corpus(t, "catalogues", "valid") {
		t.Run(filepath.Base(path), func(t *testing.T) {
			catalogue, found, err := ReadCatalogue(path)
			if err != nil {
				t.Fatalf("ReadCatalogue: %v", err)
			}
			if !found {
				t.Error("found = false for a file that is there")
			}
			if !catalogue.Offered(catalogue.Default) {
				t.Errorf("defaults to %q, which it does not offer", catalogue.Default)
			}
		})
	}
}

func TestInvalidCataloguesAreRefused(t *testing.T) {
	for _, path := range corpus(t, "catalogues", "invalid") {
		t.Run(filepath.Base(path), func(t *testing.T) {
			if catalogue, _, err := ReadCatalogue(path); err == nil {
				t.Fatalf("ReadCatalogue accepted %#v", catalogue)
			}
		})
	}
}

// A tree with no catalogue is a release from before the colourscheme was a
// choice. Not an error, and distinguishable from a catalogue that offers
// nothing — which is refused.
func TestNoCatalogueIsNotAnError(t *testing.T) {
	catalogue, found, err := LoadCatalogue(t.TempDir())
	if err != nil {
		t.Fatalf("LoadCatalogue: %v", err)
	}
	if found {
		t.Error("found = true with no file there")
	}
	if len(catalogue.Themes) != 0 {
		t.Errorf("themes = %v, want none", catalogue.IDs())
	}
	if catalogue.Choosable() {
		t.Error("a release with no catalogue is a question")
	}
}

// And a choice nobody has made is the release's own default, rather than an
// error or an empty answer.
func TestNoChoiceIsTheReleaseDefault(t *testing.T) {
	catalogue := against(t)

	choice, found, err := Load(filepath.Join(t.TempDir(), "theme.json"), catalogue)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if found {
		t.Error("found = true with no file there")
	}
	if choice.Theme != catalogue.Default {
		t.Errorf("theme = %q, want the catalogue's default %q", choice.Theme, catalogue.Default)
	}
}

// A dangling symlink is a choice somebody made pointing at nothing, and it must
// not read as a choice nobody made — that would silently swap their
// colourscheme for the default. Must match lua/chroma/theme.lua.
func TestADanglingLinkIsAProblemRatherThanAnAbsence(t *testing.T) {
	path := filepath.Join(t.TempDir(), "theme.json")
	if err := os.Symlink(filepath.Join(t.TempDir(), "gone.json"), path); err != nil {
		t.Skipf("this filesystem will not take a symlink: %v", err)
	}

	if _, found, err := Load(path, against(t)); err == nil || !found {
		t.Errorf("a dangling link gave err=%v found=%v, want a reported problem", err, found)
	}
}

// A choice is checked against a catalogue only when there is one. Nothing to
// check against is not the same as failing the check, and treating it as
// failure would refuse every choice made where the release tree is not in front
// of this process.
func TestAChoiceIsNotRefusedForWantOfACatalogue(t *testing.T) {
	path := filepath.Join(fixtures, "valid", "the-other-one.json")

	choice, _, err := Load(path, Catalogue{})
	if err != nil {
		t.Fatalf("Load without a catalogue: %v", err)
	}
	if choice.Theme != "everforest" {
		t.Errorf("theme = %q, want everforest", choice.Theme)
	}
}

// Writing refuses what reading would refuse, so a document this package wrote
// can always be read back by it.
func TestWriteRefusesWhatLoadWouldRefuse(t *testing.T) {
	catalogue := against(t)
	path := filepath.Join(t.TempDir(), "theme.json")

	if _, err := Write(path, "gruvbox", catalogue); err == nil {
		t.Error("wrote a theme the catalogue does not offer")
	}
	if _, err := os.Lstat(path); err == nil {
		t.Error("a refused write left a file behind")
	}

	if _, err := Write(path, "everforest", catalogue); err != nil {
		t.Fatalf("Write: %v", err)
	}
	choice, found, err := Load(path, catalogue)
	if err != nil || !found {
		t.Fatalf("reading back what was written: %v (found %v)", err, found)
	}
	if choice.Theme != "everforest" {
		t.Errorf("theme = %q, want everforest", choice.Theme)
	}
}

// Restore puts back bytes that were already there without reading them: what an
// installer found is not its to correct.
func TestRestorePutsBackWhatWasThere(t *testing.T) {
	path := filepath.Join(t.TempDir(), "theme.json")
	original := []byte("{ \"schema\": 99, \"theme\": \"whatever\" }\n")

	if _, err := Restore(path, original); err != nil {
		t.Fatalf("Restore: %v", err)
	}
	back, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(back) != string(original) {
		t.Errorf("restored %q, want %q byte for byte", back, original)
	}
}

// Choosable is what decides whether anybody is asked, so both edges are held.
func TestChoosableIsMoreThanOne(t *testing.T) {
	for _, tc := range []struct {
		name string
		file string
		want bool
	}{
		{"one theme is not a question", filepath.Join("catalogues", "valid", "one.json"), false},
		{"two themes are", filepath.Join("catalogues", "valid", "two.json"), true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			catalogue, _, err := ReadCatalogue(filepath.Join(fixtures, tc.file))
			if err != nil {
				t.Fatal(err)
			}
			if got := catalogue.Choosable(); got != tc.want {
				t.Errorf("Choosable = %v, want %v", got, tc.want)
			}
		})
	}
}

// The catalogue's own order is kept, because it decides what a selector shows
// first — a presentation decision that belongs to whoever wrote the release.
func TestTheCataloguesOrderIsKept(t *testing.T) {
	catalogue, _, err := ReadCatalogue(filepath.Join(fixtures, "catalogues", "valid", "no-descriptions.json"))
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.Join(catalogue.IDs(), ","); got != "everforest,catppuccin" {
		t.Errorf("IDs = %s, want the file's own order everforest,catppuccin", got)
	}
}

// The one this repository ships has to be one this reader accepts, or a release
// would install a catalogue the editor refuses.
func TestTheShippedCatalogueLoads(t *testing.T) {
	catalogue, found, err := LoadCatalogue(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatalf("the shipped %s: %v", CatalogueFile, err)
	}
	if !found {
		t.Fatalf("no %s at the root of this repository", CatalogueFile)
	}
	if !catalogue.Choosable() {
		t.Errorf("the shipped catalogue offers %v, which is not a choice", catalogue.IDs())
	}
}
