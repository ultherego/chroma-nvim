package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
	"github.com/ultherego/chroma-nvim/cli/internal/theme"
)

// offered is what the tree these tests install actually offers, read from the
// tree rather than restated here: a fixture that describes itself twice is one
// that can describe itself two ways.
func offered(t *testing.T, root string) theme.Catalogue {
	t.Helper()

	catalogue, found, err := theme.LoadCatalogue(root)
	if err != nil || !found {
		t.Fatalf("the test tree offers no catalogue: %v (found %v)", err, found)
	}
	return catalogue
}

func TestAnInstallationRecordsTheChosenTheme(t *testing.T) {
	fixed(t)

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}

	source := prepared(t)
	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Apply(
		context.Background(),
		Options{Selected: []string{}, Theme: "second"},
		paths, source, shipped(t),
	); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	choice, found, err := theme.Load(paths.ThemeFile, offered(t, source.Root))
	if err != nil || !found {
		t.Fatalf("reading back what was written: %v (found %v)", err, found)
	}
	if choice.Theme != "second" {
		t.Errorf("theme = %q, want second", choice.Theme)
	}
}

// Saying nothing is the release's own default rather than no document at all: a
// scripted install that never mentions a colourscheme still gets one, and the
// editor reads the same answer the plan showed.
func TestSayingNothingRecordsTheReleaseDefault(t *testing.T) {
	fixed(t)

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}

	source := prepared(t)
	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Apply(
		context.Background(),
		Options{Selected: []string{}},
		paths, source, shipped(t),
	); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	choice, _, err := theme.Load(paths.ThemeFile, offered(t, source.Root))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if want := offered(t, source.Root).Default; choice.Theme != want {
		t.Errorf("theme = %q, want the release's default %q", choice.Theme, want)
	}
}

// A release from before the colourscheme was a choice has no answer to record,
// and inventing one would be this installer writing a preference nobody stated.
func TestATreeWithNoCatalogueWritesNoTheme(t *testing.T) {
	fixed(t)

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}

	source := prepared(t)
	if err := os.Remove(filepath.Join(source.Root, theme.CatalogueFile)); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Apply(
		context.Background(),
		Options{Selected: []string{}},
		paths, source, shipped(t),
	); err != nil {
		t.Fatalf("Apply: %v", err)
	}

	if exists(paths.ThemeFile) {
		t.Errorf("%s was written for a release that offers no choice of theme", paths.ThemeFile)
	}
}

// A theme this release does not have is refused before anything is written,
// rather than recorded and then read back as a colourscheme nobody can draw.
func TestAThemeTheReleaseDoesNotOfferIsRefused(t *testing.T) {
	fixed(t)

	xdg(t, t.TempDir())
	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Apply(
		context.Background(),
		Options{Selected: []string{}, Theme: "gruvbox"},
		paths, prepared(t), shipped(t),
	); err == nil {
		t.Fatal("Apply accepted a theme the release does not offer")
	}

	if exists(paths.ThemeFile) {
		t.Errorf("%s was written by an installation that was refused", paths.ThemeFile)
	}
}

// The transaction's half of the same rule, on its own: what was there comes
// back, and what was not there does not appear.
func TestRollbackPutsTheThemeBack(t *testing.T) {
	tx, paths := newTransaction(t)
	catalogue := offered(t, prepared(t).Root)

	if err := os.MkdirAll(filepath.Dir(paths.ThemeFile), 0o755); err != nil {
		t.Fatal(err)
	}
	before := "{\n  \"schema\": 1,\n  \"theme\": \"first\"\n}\n"
	if err := os.WriteFile(paths.ThemeFile, []byte(before), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := tx.WriteTheme("second", catalogue); err != nil {
		t.Fatalf("WriteTheme: %v", err)
	}
	if got := readFile(t, paths.ThemeFile); !strings.Contains(got, "second") {
		t.Fatalf("the write did not take: %s", got)
	}

	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}
	if got := readFile(t, paths.ThemeFile); got != before {
		t.Errorf("restored %q, want %q byte for byte", got, before)
	}
}

func TestRollbackRemovesAThemeThatWasNotThere(t *testing.T) {
	tx, paths := newTransaction(t)

	if err := tx.WriteTheme("second", offered(t, prepared(t).Root)); err != nil {
		t.Fatalf("WriteTheme: %v", err)
	}
	if err := tx.Rollback(); err != nil {
		t.Fatalf("Rollback: %v", err)
	}

	if exists(paths.ThemeFile) {
		t.Errorf("%s survived a rollback that never had one to put back", paths.ThemeFile)
	}
}

// An update moves the version and does not touch a choice. Measured here rather
// than argued: writing the new release's default over somebody's own theme is
// the failure this is guarding.
func TestAnUpdateLeavesTheThemeAlone(t *testing.T) {
	fixed(t)

	root := t.TempDir()
	paths, current := installedUnder(t, root, []string{"terraform"})

	if _, err := theme.Write(paths.ThemeFile, "second", offered(t, prepared(t).Root)); err != nil {
		t.Fatalf("Write: %v", err)
	}

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Update(
		context.Background(), paths, prepared(t), shipped(t), []string{"terraform"}, current,
	); err != nil {
		t.Fatalf("Update: %v", err)
	}

	choice, _, err := theme.Load(paths.ThemeFile, offered(t, prepared(t).Root))
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if choice.Theme != "second" {
		t.Errorf("theme = %q after an update, want the one that was chosen", choice.Theme)
	}
}

// And an uninstall takes it with the rest, including the directory it lived in.
// Left behind, it is an orphan in a directory nothing else claims — the failure
// class the selection's own removal was added for.
func TestUninstallRemovesTheThemeAndItsDirectory(t *testing.T) {
	fixed(t)

	paths, current, _ := takenOver(t)
	if _, err := theme.Write(paths.ThemeFile, "second", offered(t, prepared(t).Root)); err != nil {
		t.Fatalf("Write: %v", err)
	}

	plan := PlanUninstall(paths, current)
	listed := false
	for _, path := range plan.Remove {
		if path == paths.ThemeFile {
			listed = true
		}
	}
	if !listed {
		t.Errorf("the plan does not remove %s: %v", paths.ThemeFile, plan.Remove)
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, current); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	if exists(paths.ThemeFile) {
		t.Errorf("%s is still there", paths.ThemeFile)
	}
	if exists(filepath.Dir(paths.ThemeFile)) {
		t.Errorf("%s is still there, empty", filepath.Dir(paths.ThemeFile))
	}
}

// A plan does not offer to remove a file that is not there, which is what an
// installation of a release from before the colourscheme was a choice leaves.
func TestThePlanDoesNotOfferToRemoveAThemeThatIsNotThere(t *testing.T) {
	fixed(t)

	paths, current, _ := takenOver(t)

	// What an installation of a release from before the colourscheme was a
	// choice looks like: everything else recorded, and no theme document.
	if err := os.Remove(paths.ThemeFile); err != nil {
		t.Fatal(err)
	}

	for _, path := range PlanUninstall(paths, current).Remove {
		if path == paths.ThemeFile {
			t.Errorf("the plan removes %s, which is not there", paths.ThemeFile)
		}
	}
}

// The theme lives beside the selection and outside the release tree, for the
// reason the selection does: an update replaces the configuration directory
// wholesale.
func TestTheThemeIsNotInsideTheReleaseTree(t *testing.T) {
	xdg(t, t.TempDir())

	paths, err := ResolvePaths(false)
	if err != nil {
		t.Fatal(err)
	}

	if strings.HasPrefix(paths.ThemeFile, paths.ConfigDir+string(os.PathSeparator)) {
		t.Errorf("%s is inside %s, which an update replaces wholesale", paths.ThemeFile, paths.ConfigDir)
	}
	if filepath.Dir(paths.ThemeFile) != filepath.Dir(paths.SelectionFile) {
		t.Errorf("the theme is at %s and the selection at %s; they belong together",
			paths.ThemeFile, paths.SelectionFile)
	}
}

// And the record still says nothing about it, deliberately: see PlanUninstall.
// Held so that adding the field later is a decision rather than an accident.
func TestTheInstallRecordDoesNotCarryTheTheme(t *testing.T) {
	contents, err := os.ReadFile(filepath.Join("..", "installstate", "installstate.go"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(contents), "theme_file") {
		t.Error("install.json now records the theme; PlanUninstall's note about why it does not is stale")
	}
	if installstate.Schema != 6 {
		t.Errorf("the install record schema is %d; this note was written against 6", installstate.Schema)
	}
}
