package install

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// The measurement that produced this file, on a real machine and a released
// binary:
//
//	.config/nvim         survived
//	.local/share/nvim    GONE   ← the plugins
//	.local/state/nvim    GONE   ← the undo history
//	.cache/nvim          GONE
//
// `--default` took over one directory and Neovim used four. What follows is the
// gate that says it never happens again: four directories with real contents
// go in, a full install-and-uninstall runs over them, and every one of them
// comes back byte for byte.

// theirs fills all four of Neovim's directories with work nobody wants lost.
//
// Built from the resolved paths rather than from `.config/nvim` and friends,
// because where those actually are is what XDG decides and hard-coding it is
// how a test ends up writing to the home directory of whoever runs it.
func theirs(t *testing.T, paths Paths) []string {
	t.Helper()

	files := map[string]string{
		filepath.Join(paths.ConfigDir, "init.lua"):                       "-- mine, not Chroma's\n",
		filepath.Join(paths.ConfigDir, "lua", "mine", "keys.lua"):        "return {}\n",
		filepath.Join(paths.DataDir, "site", "pack", "plugin", "go.lua"): "-- a plugin from 2019\n",
		filepath.Join(paths.DataDir, "lazy", "telescope", "README.md"):   "# telescope\n",
		filepath.Join(paths.StateDir, "undo", "%home%somebody%notes.md"): "\x00undo history\n",
		filepath.Join(paths.StateDir, "shada", "main.shada"):             "\x01marks\n",
		filepath.Join(paths.CacheDir, "luac", "compiled"):                "\x02bytecode\n",
	}
	for path, contents := range files {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	return []string{paths.ConfigDir, paths.DataDir, paths.StateDir, paths.CacheDir}
}

// neovims resolves where Neovim's own directories are under a test root.
func neovims(t *testing.T, root string) Paths {
	t.Helper()

	xdg(t, root)
	paths, err := ResolvePaths(true)
	if err != nil {
		t.Fatalf("ResolvePaths: %v", err)
	}
	return paths
}

// put writes a file and whatever directories it needs.
func put(t *testing.T, path, contents string) {
	t.Helper()

	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(contents), 0o644); err != nil {
		t.Fatal(err)
	}
}

// manifest is every file under a directory and what is in it, so that "the same
// as before" is a comparison rather than an impression.
func manifest(t *testing.T, root string) map[string]string {
	t.Helper()

	found := map[string]string{}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() {
			return nil
		}
		contents, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		digest := sha256.Sum256(contents)
		found[relative] = hex.EncodeToString(digest[:])
		return nil
	})
	if err != nil && !os.IsNotExist(err) {
		t.Fatalf("reading %s: %v", root, err)
	}
	return found
}

// compare says exactly what differs, because "manifests differ" is not a bug
// report.
func compare(t *testing.T, what string, before, after map[string]string) {
	t.Helper()

	var problems []string
	for name, want := range before {
		got, still := after[name]
		switch {
		case !still:
			problems = append(problems, fmt.Sprintf("  %s is gone", name))
		case got != want:
			problems = append(problems, fmt.Sprintf("  %s changed", name))
		}
	}
	for name := range after {
		if _, was := before[name]; !was {
			problems = append(problems, fmt.Sprintf("  %s was left behind", name))
		}
	}

	if len(problems) > 0 {
		sort.Strings(problems)
		t.Errorf("%s did not come back as it was:\n%s", what, strings.Join(problems, "\n"))
	}
}

// takeoverOver runs a real `--default` installation over a populated home.
func takeoverOver(t *testing.T, paths Paths) installstate.State {
	t.Helper()

	installer := &Installer{Runner: &failAt{}}
	result, err := installer.Apply(context.Background(), Options{Selected: nil, UseDefault: true}, paths, prepared(t), shipped(t))
	if err != nil {
		t.Fatalf("the takeover failed: %v", err)
	}
	return result.State
}

// **The gate.** Four directories in, four directories back.
func TestATakeoverGivesBackAllFourOfNeovimsDirectories(t *testing.T) {
	fixed(t)

	paths := neovims(t, t.TempDir())
	homes := theirs(t, paths)

	before := map[string]map[string]string{}
	for _, home := range homes {
		before[home] = manifest(t, home)
	}

	record := takeoverOver(t, paths)

	// All four were taken, and each says which it is.
	if len(record.Borrowed) != 4 {
		t.Fatalf("borrowed %d directories, want 4: %+v", len(record.Borrowed), record.Borrowed)
	}
	for _, one := range record.Borrowed {
		if one.Device == 0 && one.Inode == 0 {
			t.Errorf("your %s was taken with no identity recorded", one.Kind)
		}
		if exists(one.Original) && !exists(one.Backup) {
			t.Errorf("your %s is not at %s", one.Kind, one.Backup)
		}
	}

	// Chroma is really in Neovim's own directory, so this is the case that
	// matters and not an installation beside it.
	if paths.AppName != "" {
		t.Fatalf("appname = %q, so this is not the default installation", paths.AppName)
	}

	// Something is written into each of the borrowed directories' places, the
	// way a bootstrap would, so the removal below has something to remove.
	for _, dir := range []string{paths.DataDir, paths.StateDir, paths.CacheDir} {
		put(t, filepath.Join(dir, "chroma-put-this-here"), "not the user's\n")
	}

	installer := &Installer{}
	removal, err := installer.Uninstall(paths, record)
	if err != nil {
		t.Fatalf("Uninstall: %v", err)
	}
	if removal.Restored == "" {
		t.Error("the uninstall reports restoring nothing")
	}

	for _, home := range homes {
		compare(t, home, before[home], manifest(t, home))
	}
}

// The same, for somebody who deleted their init.lua years ago and still has
// everything else. `~/.config/nvim` being absent used to mean "nothing to back
// up", and the other three were then removed as Chroma's own.
func TestATakeoverWithNoConfigurationStillGivesBackTheRest(t *testing.T) {
	fixed(t)

	paths := neovims(t, t.TempDir())
	homes := theirs(t, paths)[1:]
	if err := os.RemoveAll(paths.ConfigDir); err != nil {
		t.Fatal(err)
	}

	before := map[string]map[string]string{}
	for _, home := range homes {
		before[home] = manifest(t, home)
	}

	record := takeoverOver(t, paths)

	if len(record.Borrowed) != 3 {
		t.Fatalf("borrowed %d directories, want 3: %+v", len(record.Borrowed), record.Borrowed)
	}
	for _, one := range record.Borrowed {
		if one.Kind == "configuration" {
			t.Error("a configuration that was not there was recorded as borrowed")
		}
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, record); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	for _, home := range homes {
		compare(t, home, before[home], manifest(t, home))
	}
	if exists(paths.ConfigDir) {
		t.Error("a configuration directory was left behind that nobody had")
	}
}

// An installation of its own borrows nothing, and must not start pretending it
// does: the directories under `chroma-nvim` are Chroma's outright.
func TestAnIsolatedInstallationBorrowsNothing(t *testing.T) {
	fixed(t)

	root := t.TempDir()
	homes := theirs(t, neovims(t, root))

	before := map[string]map[string]string{}
	for _, home := range homes {
		before[home] = manifest(t, home)
	}

	paths, record := installedUnder(t, root, nil)
	if paths.AppName != AppName {
		t.Fatalf("appname = %q, so this is not an installation of its own", paths.AppName)
	}
	if len(record.Borrowed) != 0 {
		t.Errorf("an installation beside Neovim claimed to borrow %+v", record.Borrowed)
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, record); err != nil {
		t.Fatalf("Uninstall: %v", err)
	}

	// Nothing of Neovim's own was touched, because nothing of Neovim's own was
	// ever in the way.
	for home, was := range before {
		compare(t, home, was, manifest(t, home))
	}
}

// Somebody else's directory at the recorded path is not the directory that was
// taken, whichever of the four it is. Measured on the configuration; asserted
// here on the data directory, because that is the one whose loss cost the most.
func TestAnUninstallRefusesASubstitutedDataDirectory(t *testing.T) {
	fixed(t)

	paths := neovims(t, t.TempDir())
	theirs(t, paths)
	record := takeoverOver(t, paths)

	var data installstate.Borrowed
	for _, one := range record.Borrowed {
		if one.Kind == "data" {
			data = one
		}
	}
	if data.Backup == "" {
		t.Fatal("no data directory was borrowed, so this proves nothing")
	}

	before := manifest(t, data.Backup)
	if err := os.RemoveAll(data.Backup); err != nil {
		t.Fatal(err)
	}
	put(t, filepath.Join(data.Backup, "site", "pack", "plugin", "go.lua"), "-- somebody else's\n")

	installer := &Installer{}
	_, err := installer.Uninstall(paths, record)
	if err == nil {
		t.Error("a directory that was never the user's data was handed back as it")
	}

	// And the substitution was not moved anywhere: a refusal leaves what it
	// refused where it found it.
	if len(manifest(t, data.Backup)) == 0 {
		t.Error("the substituted directory was moved despite the refusal")
	}
	if len(before) == 0 {
		t.Fatal("the fixture had no data to lose")
	}
}

// bootstrapping is a runner that does what a real bootstrap does to a machine:
// it fills Neovim's other three directories, and the CLI's own log appears in
// the state one. Then it fails at the step named, or not at all.
//
// The runner the rest of this package uses creates nothing, which is how a
// takeover that could not be undone passed every test here.
type bootstrapping struct {
	paths Paths
	fail  string
}

func (b *bootstrapping) Run(_ context.Context, cmd Command, _ ProgressSink) error {
	for _, dir := range []string{b.paths.DataDir, b.paths.StateDir, b.paths.CacheDir} {
		if err := os.MkdirAll(filepath.Join(dir, "lazy"), 0o755); err != nil {
			return err
		}
		if err := os.WriteFile(filepath.Join(dir, "lazy", "fetched"), []byte("chroma"), 0o644); err != nil {
			return err
		}
	}
	if err := os.MkdirAll(b.paths.LogDir, 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(b.paths.LogDir, "install-20260809T134200Z.log"), []byte("why it failed\n"), 0o644); err != nil {
		return err
	}

	if b.fail != "" && strings.Contains(strings.Join(cmd.Args, " "), `run("`+b.fail+`"`) {
		return fmt.Errorf("the editor said no")
	}
	return nil
}

// Regression, measured on this code before the fix: the bootstrap had made new
// directories where the borrowed ones belonged, every rename back failed with
// "file exists", and `~/.config/nvim` was simply absent afterwards.
func TestAFailedTakeoverGivesBackAllFourAfterARealBootstrap(t *testing.T) {
	for _, step := range []string{"install", "verify"} {
		t.Run(step, func(t *testing.T) {
			fixed(t)
			paths := neovims(t, t.TempDir())
			homes := theirs(t, paths)

			before := map[string]map[string]string{}
			for _, home := range homes {
				before[home] = manifest(t, home)
			}

			installer := &Installer{Runner: &bootstrapping{paths: paths, fail: step}}
			result, err := installer.Apply(context.Background(), Options{UseDefault: true}, paths, prepared(t), shipped(t))
			if err == nil {
				t.Fatal("the installation succeeded, and it was meant to fail")
			}
			if result.RollbackProblem != nil {
				t.Fatalf("putting things back did not entirely work: %v", result.RollbackProblem)
			}

			for _, home := range homes {
				compare(t, home, before[home], manifest(t, home))
			}

			// The log of the failure is the one thing somebody needs next, so
			// what was moved out of the way is named and the log is in it.
			if len(result.LeftBehind) != 3 {
				t.Fatalf("left behind %v, want the data, state and cache the bootstrap made", result.LeftBehind)
			}
			logs := 0
			for _, left := range result.LeftBehind {
				if !strings.Contains(filepath.Base(left), failedMark) {
					t.Errorf("%s is not named as a failed installation's", left)
				}
				if exists(filepath.Join(left, "logs", "install-20260809T134200Z.log")) {
					logs++
				}
				if !strings.Contains(result.Describe(), left) {
					t.Errorf("the report does not say where %s went:\n%s", left, result.Describe())
				}
			}
			if logs != 1 {
				t.Errorf("the failure's log is in %d of the directories left behind, want 1", logs)
			}

			// And nothing is left that recovery would read as a generation.
			for _, home := range homes {
				matches, _ := filepath.Glob(home + backupMark + "*")
				if len(matches) != 0 {
					t.Errorf("%v still beside %s", matches, home)
				}
			}
		})
	}
}

// One directory that cannot go back must not cost the others theirs. The slice
// of what is still owed used to share its array with the one being walked, so a
// failure at the last entry overwrote the first before the loop got to it.
func TestOneDirectoryThatCannotGoBackDoesNotStopTheOthers(t *testing.T) {
	fixed(t)
	paths := neovims(t, t.TempDir())
	homes := theirs(t, paths)

	before := map[string]map[string]string{}
	for _, home := range homes {
		before[home] = manifest(t, home)
	}

	tx := &Transaction{}
	if err := tx.Borrow(paths); err != nil {
		t.Fatal(err)
	}
	if len(tx.Borrowed) != 4 {
		t.Fatalf("borrowed %d directories, want 4", len(tx.Borrowed))
	}

	// The last one taken is no longer what was recorded, so it is refused.
	last := tx.Borrowed[len(tx.Borrowed)-1]
	tx.Borrowed[len(tx.Borrowed)-1].Inode = last.Inode + 1

	if err := tx.giveBackBorrowed(); err == nil {
		t.Fatal("a substituted directory was given back without a word")
	}

	if len(tx.Borrowed) != 1 || tx.Borrowed[0].Original != last.Original {
		t.Fatalf("still owed %+v, want only %s", tx.Borrowed, last.Original)
	}
	for _, home := range homes {
		if home == last.Original {
			continue
		}
		compare(t, home, before[home], manifest(t, home))
	}
}
