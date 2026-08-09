package release

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// tree builds a checkout: the runtime, and the development around it.
func tree(t *testing.T) string {
	t.Helper()

	root := t.TempDir()
	for _, file := range []struct{ path, contents string }{
		{"init.lua", "-- a configuration\n"},
		{"lazy-lock.json", "{}\n"},
		{"README.md", "# Chroma\n"},
		{"LICENSE", "MIT\n"},
		{"lua/chroma/state.lua", "return {}\n"},
		{"lua/chroma/bootstrap.lua", "return {}\n"},
		{"components/core.json", `{"contract": 5, "id": "core"}` + "\n"},
		{"after/lsp/yamlls.lua", "return {}\n"},
		{"doc/chroma-nvim.txt", "help\n"},
		{"assets/logo.png", "not really a png\n"},

		// Everything a release is not.
		{"cli/cmd/chroma/main.go", "package main\n"},
		{"tests/test_state.lua", "return {}\n"},
		{".github/workflows/ci.yml", "name: CI\n"},
		{".git/HEAD", "ref: refs/heads/main\n"},
		{"CONTRACT.md", "rules\n"},
		{"DECISIONS.md", "reasons\n"},
		{"audit.md", "an audit\n"},
		{"selene.toml", "std = \"lua51\"\n"},
	} {
		full := filepath.Join(root, filepath.FromSlash(file.path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatalf("creating %s: %v", full, err)
		}
		if err := os.WriteFile(full, []byte(file.contents), 0o644); err != nil {
			t.Fatalf("writing %s: %v", full, err)
		}
	}
	return root
}

// entries lists what an archive holds, by name.
func entries(t *testing.T, path string) []string {
	t.Helper()

	handle, err := os.Open(path)
	if err != nil {
		t.Fatalf("opening %s: %v", path, err)
	}
	defer handle.Close()

	compressed, err := gzip.NewReader(handle)
	if err != nil {
		t.Fatalf("reading %s as gzip: %v", path, err)
	}

	var names []string
	archive := tar.NewReader(compressed)
	for {
		header, err := archive.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("reading %s: %v", path, err)
		}
		names = append(names, header.Name)
	}
	sort.Strings(names)
	return names
}

func TestAnArchiveHoldsTheRuntimeAndNothingElse(t *testing.T) {
	out := t.TempDir()

	result, err := Package(tree(t), "v1.0.0", out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	names := entries(t, result.Archive)
	joined := strings.Join(names, "\n")

	for _, wanted := range []string{
		"chroma-nvim-v1.0.0/init.lua",
		"chroma-nvim-v1.0.0/lua/chroma/state.lua",
		"chroma-nvim-v1.0.0/lua/chroma/bootstrap.lua",
		"chroma-nvim-v1.0.0/components/core.json",
		"chroma-nvim-v1.0.0/after/lsp/yamlls.lua",
		"chroma-nvim-v1.0.0/doc/chroma-nvim.txt",
		"chroma-nvim-v1.0.0/lazy-lock.json",
	} {
		if !strings.Contains(joined, wanted) {
			t.Errorf("the archive has no %s", wanted)
		}
	}

	// What a release is not. `.git` in particular: an installed configuration
	// that is a checkout invites `git pull` over a managed installation.
	for _, unwanted := range []string{"/cli/", "/tests/", "/.github/", "/.git/", "CONTRACT.md", "audit.md", "selene.toml"} {
		if strings.Contains(joined, unwanted) {
			t.Errorf("the archive carries %s", unwanted)
		}
	}
}

// Every entry under the name the archive claims to be, so an extractor can
// check that too rather than trusting what it unpacks.
func TestEveryEntryIsUnderThePrefix(t *testing.T) {
	out := t.TempDir()

	result, err := Package(tree(t), "v1.0.0", out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	for _, name := range entries(t, result.Archive) {
		if !strings.HasPrefix(name, "chroma-nvim-v1.0.0/") {
			t.Errorf("%q is not under the archive's own prefix", name)
		}
	}
}

// A checksum that changed between two builds of the same tree would be a record
// of when the archive was made rather than of what is in it.
func TestPackagingIsReproducible(t *testing.T) {
	source := tree(t)

	first, err := Package(source, "v1.0.0", t.TempDir())
	if err != nil {
		t.Fatalf("first Package: %v", err)
	}
	second, err := Package(source, "v1.0.0", t.TempDir())
	if err != nil {
		t.Fatalf("second Package: %v", err)
	}

	if first.SHA256 != second.SHA256 {
		t.Errorf("two builds of one tree differ: %s and %s", first.SHA256, second.SHA256)
	}
}

// The checksum is the point of the file, so it is checked against the bytes on
// disk rather than against the number the packager reported.
func TestTheRecordedChecksumIsTheArchivesOwn(t *testing.T) {
	out := t.TempDir()

	result, err := Package(tree(t), "v1.0.0", out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	contents, err := os.ReadFile(result.Archive)
	if err != nil {
		t.Fatalf("reading the archive: %v", err)
	}
	actual := sha256.Sum256(contents)
	if hex.EncodeToString(actual[:]) != result.SHA256 {
		t.Errorf("the reported checksum is not the archive's")
	}

	sums, err := os.ReadFile(result.Sums)
	if err != nil {
		t.Fatalf("reading %s: %v", SumsName, err)
	}
	parsed, err := ReadSums(sums)
	if err != nil {
		t.Fatalf("ReadSums: %v", err)
	}
	if parsed[ArchiveName("v1.0.0")] != result.SHA256 {
		t.Errorf("%s records %q, want %q", SumsName, parsed[ArchiveName("v1.0.0")], result.SHA256)
	}
}

// The installer copies RuntimeEntries when it stages a checkout. If the
// packager used a different list, an installation from a release and one from a
// tree would be different products with the same version.
func TestThePackagerAndTheInstallerAgreeOnWhatARuntimeIs(t *testing.T) {
	out := t.TempDir()

	result, err := Package(tree(t), "v1.0.0", out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	joined := strings.Join(entries(t, result.Archive), "\n")
	for _, entry := range install.RuntimeEntries {
		// The fixture does not carry every optional entry; the ones it has must
		// all be in the archive.
		if entry == "assets" {
			continue
		}
		if !strings.Contains(joined, "chroma-nvim-v1.0.0/"+entry) {
			t.Errorf("the archive is missing runtime entry %q", entry)
		}
	}
}

func TestASymlinkIsRefused(t *testing.T) {
	source := tree(t)
	if err := os.Symlink(filepath.Join(source, "init.lua"), filepath.Join(source, "lua", "elsewhere.lua")); err != nil {
		t.Skipf("this filesystem will not take a symlink: %v", err)
	}

	_, err := Package(source, "v1.0.0", t.TempDir())
	if err == nil {
		t.Fatal("packaged a tree containing a symlink")
	}
	if !strings.Contains(err.Error(), "symlink") {
		t.Errorf("err = %v, want it to say what was wrong", err)
	}
}

func TestPackageRefusesWhatItCannotName(t *testing.T) {
	if _, err := Package(tree(t), "", t.TempDir()); err == nil {
		t.Error("packaged a release with no version")
	}
	if _, err := Package("relative/tree", "v1.0.0", t.TempDir()); err == nil {
		t.Error("packaged a tree named by a relative path")
	}
}

func TestReadSumsRefusesWhatItCannotParse(t *testing.T) {
	for _, tc := range []struct{ name, contents string }{
		{"no separator", "abc123 chroma.tar.gz\n"},
		{"not a digest", "nothexatall  chroma.tar.gz\n"},
		{"a short digest", "abc123  chroma.tar.gz\n"},
		{"nothing at all", "\n\n"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := ReadSums([]byte(tc.contents)); err == nil {
				t.Error("accepted a checksum file that cannot be trusted")
			}
		})
	}

	sums, err := ReadSums([]byte(strings.Repeat("a", 64) + "  chroma-nvim-v1.0.0.tar.gz\n"))
	if err != nil {
		t.Fatalf("ReadSums: %v", err)
	}
	if sums["chroma-nvim-v1.0.0.tar.gz"] != strings.Repeat("a", 64) {
		t.Errorf("parsed %v", sums)
	}
}

// A release says "built from commit X" and a tag points at X. Both are false if
// the runtime files differ from what X holds — the case this exists for, which
// arrived as an archive carrying a lazy-lock.json that a `:Lazy sync` had
// changed and nobody had committed.
func TestAttributeReportsTheCommitAndWhatDiffersFromIt(t *testing.T) {
	root := tree(t)
	run := func(args ...string) {
		t.Helper()
		command := exec.Command("git", append([]string{"-C", root}, args...)...)
		command.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.com",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.com")
		if output, err := command.CombinedOutput(); err != nil {
			t.Skipf("git is not usable here: %v %s", err, output)
		}
	}

	run("init", "--quiet")
	run("add", ".")
	run("commit", "--quiet", "-m", "everything")

	clean, err := Attribute(root)
	if err != nil {
		t.Fatalf("Attribute: %v", err)
	}
	if len(clean.Commit) != 40 {
		t.Errorf("commit = %q, want a full sha", clean.Commit)
	}
	if len(clean.Dirty) != 0 {
		t.Errorf("a freshly committed tree reported %v", clean.Dirty)
	}

	// A runtime file the archive carries.
	if err := os.WriteFile(filepath.Join(root, "lazy-lock.json"), []byte(`{"catppuccin": {"commit": "beef"}}`+"\n"), 0o644); err != nil {
		t.Fatalf("changing the lockfile: %v", err)
	}
	dirty, err := Attribute(root)
	if err != nil {
		t.Fatalf("Attribute: %v", err)
	}
	if len(dirty.Dirty) != 1 || !strings.Contains(dirty.Dirty[0], "lazy-lock.json") {
		t.Errorf("dirty = %v, want the lockfile", dirty.Dirty)
	}

	// And a file that is not in the archive does not make it unattributable.
	if err := os.WriteFile(filepath.Join(root, "CONTRACT.md"), []byte("changed\n"), 0o644); err != nil {
		t.Fatalf("changing a file outside the archive: %v", err)
	}
	stillOne, err := Attribute(root)
	if err != nil {
		t.Fatalf("Attribute: %v", err)
	}
	if len(stillOne.Dirty) != 1 {
		t.Errorf("dirty = %v; a file outside the archive is not the archive's problem", stillOne.Dirty)
	}
}

// A tree that cannot say where it came from is not something to build a release
// out of.
func TestAttributeRefusesSomethingThatIsNotACheckout(t *testing.T) {
	if _, err := Attribute(t.TempDir()); err == nil {
		t.Error("attributed a directory that is not a checkout")
	}
}
