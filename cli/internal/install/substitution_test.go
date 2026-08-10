package install

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// precious builds a directory standing in for whatever somebody actually cares
// about, and looking enough like a configuration to get past a shallow check.
func precious(t *testing.T, at string) string {
	t.Helper()

	if err := os.MkdirAll(filepath.Join(at, "lua", "chroma"), 0o755); err != nil {
		t.Fatal(err)
	}
	write(t, filepath.Join(at, "init.lua"), "-- years of work\n")
	write(t, filepath.Join(at, "lua", "chroma", "bootstrap.lua"), "return {}\n")
	return at
}

// H4: a path in the record proves where Chroma once put something. It does not
// prove what is there now. Somebody replaces the kept generation with a link to
// a directory of their own.
func TestARollbackRefusesASubstitutedGeneration(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	keptAt := current.Previous.Path

	important := precious(t, filepath.Join(t.TempDir(), "important"))
	if err := os.RemoveAll(keptAt); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(important, keptAt); err != nil {
		t.Fatal(err)
	}

	before, err := os.ReadFile(paths.InstallState)
	if err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current); err == nil {
		t.Error("a symbolic link was restored as the previous generation")
	}

	if !exists(filepath.Join(important, "init.lua")) {
		t.Error("the directory behind the link is gone")
	}
	if target, err := os.Readlink(keptAt); err != nil || target != important {
		t.Errorf("the link itself was moved: %q %v", target, err)
	}
	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("the installed configuration is gone")
	}

	after, err := os.ReadFile(paths.InstallState)
	if err != nil {
		t.Fatal(err)
	}
	if string(after) != string(before) {
		t.Error("the record changed despite the refusal")
	}
}

// A link pointing at nothing is the same class: the recorded identity cannot be
// trusted, whatever is or is not on the other end.
func TestARollbackRefusesADanglingGeneration(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	keptAt := current.Previous.Path

	if err := os.RemoveAll(keptAt); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(t.TempDir(), "never-existed"), keptAt); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current); err == nil {
		t.Error("a dangling link was restored as the previous generation")
	}
	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("the installed configuration is gone")
	}
}

// The one with the largest blast radius: the configuration Chroma is holding for
// somebody is replaced with a link into a directory of theirs. The refusal has
// to come before `pending` is written — once Chroma cannot prove what is at that
// path, it has no business starting a transfer of ownership at all.
func TestAnUninstallRefusesASubstitutedUserBackup(t *testing.T) {
	fixed(t)

	paths, current, userBackup := takenOver(t)

	important := precious(t, filepath.Join(t.TempDir(), "important"))
	if err := os.RemoveAll(userBackup); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(important, userBackup); err != nil {
		t.Fatal(err)
	}

	installer := &Installer{}
	if _, err := installer.Uninstall(paths, current); err == nil {
		t.Error("a symbolic link was handed back as the user's configuration")
	}

	if !exists(filepath.Join(important, "init.lua")) {
		t.Fatal("the directory behind the link is gone")
	}

	record, found, err := installstate.Load(paths.InstallState)
	if err != nil || !found {
		t.Fatalf("Load: %v found=%v", err, found)
	}
	if record.Handover != installstate.HandoverHeld {
		t.Errorf("handover = %q, want it still held: the transfer must not have begun", record.Handover)
	}
	if !isChromaTree(paths.ConfigDir) {
		t.Error("the installation was moved despite the refusal")
	}
}

// The same class without a link: the recorded directory replaced by a file.
func TestARecordedPathThatIsNoLongerADirectoryIsRefused(t *testing.T) {
	fixed(t)

	paths, current := twoGenerations(t, nil)
	keptAt := current.Previous.Path

	if err := os.RemoveAll(keptAt); err != nil {
		t.Fatal(err)
	}
	write(t, keptAt, "not a configuration at all\n")

	installer := &Installer{Runner: &failAt{}}
	if _, err := installer.Rollback(context.Background(), paths, shipped(t), nil, current); err == nil {
		t.Error("a regular file was restored as the previous generation")
	}
	if !exists(filepath.Join(paths.ConfigDir, "init.lua")) {
		t.Error("the installed configuration is gone")
	}
}

// And the refusal says which kind of surprise it found, because the two lead
// somebody to look in different places.
func TestTheRefusalNamesWhatItFound(t *testing.T) {
	dir := t.TempDir()

	link := filepath.Join(dir, "link")
	if err := os.Symlink(filepath.Join(dir, "elsewhere"), link); err != nil {
		t.Fatal(err)
	}
	err := RefuseSubstituted(link)
	if err == nil || !strings.Contains(err.Error(), "symbolic link") {
		t.Errorf("a link was not reported as one: %v", err)
	}
	if !strings.Contains(err.Error(), filepath.Join(dir, "elsewhere")) {
		t.Errorf("the refusal does not say where the link points: %v", err)
	}

	file := filepath.Join(dir, "file")
	write(t, file, "x\n")
	err = RefuseSubstituted(file)
	if err == nil || !strings.Contains(err.Error(), "not a directory") {
		t.Errorf("a regular file was not reported as one: %v", err)
	}
}
