// Package release builds the artefacts a release is made of. One packager, used
// by a developer making a prerelease by hand and by the release workflow: an
// archive built one way in development and another in CI is an archive whose
// checksum proves nothing about what was tested.
package release

import (
	"archive/tar"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// Prefix is the directory every archive entry lives under:
// `chroma-nvim-v1.0.0/init.lua`, not `init.lua`. A tarball that explodes into
// the working directory is rude, and a required prefix is one more thing the
// extractor can check.
func Prefix(version string) string {
	return "chroma-nvim-" + version
}

// ArchiveName is what the release asset is called.
func ArchiveName(version string) string {
	return Prefix(version) + ".tar.gz"
}

// SumsName is the file listing the checksum of every asset.
const SumsName = "SHA256SUMS"

// stamp is the modification time written into every entry.
//
// Fixed, so that packaging the same tree twice produces the same bytes and
// therefore the same checksum. A timestamp that moved would make SHA256SUMS a
// record of when the archive was built rather than of what is in it.
var stamp = time.Unix(0, 0).UTC()

// Result is what was written.
type Result struct {
	Archive string
	Sums    string
	SHA256  string
}

// Package writes the release archive and its checksum file. What goes in is
// install.RuntimeEntries — the same list the installer copies from a developer
// checkout, so an installation from a release and one from a tree contain the
// same files.
func Package(tree, version, outDir string, assets ...string) (Result, error) {
	if version == "" {
		return Result{}, errors.New("a release needs a version")
	}
	if !filepath.IsAbs(tree) {
		return Result{}, fmt.Errorf("%q is not an absolute path", tree)
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return Result{}, fmt.Errorf("creating %s: %w", outDir, err)
	}

	archivePath := filepath.Join(outDir, ArchiveName(version))
	handle, err := os.Create(archivePath)
	if err != nil {
		return Result{}, fmt.Errorf("creating %s: %w", archivePath, err)
	}

	// The checksum is computed from the bytes that are written, not from the
	// file afterwards: there is then no window in which the two could differ.
	digest := sha256.New()
	compressed := gzip.NewWriter(io.MultiWriter(handle, digest))
	archive := tar.NewWriter(compressed)

	if err := writeTree(archive, tree, version); err != nil {
		archive.Close()
		compressed.Close()
		handle.Close()
		os.Remove(archivePath)
		return Result{}, err
	}

	for _, closer := range []io.Closer{archive, compressed, handle} {
		if err := closer.Close(); err != nil {
			os.Remove(archivePath)
			return Result{}, fmt.Errorf("finishing %s: %w", archivePath, err)
		}
	}

	sum := hex.EncodeToString(digest.Sum(nil))

	// One SHA256SUMS for everything the release publishes, written here rather
	// than assembled by the workflow. The alternative is a shell pipeline that
	// agrees with this code today, and a release whose checksums were produced
	// by something nobody tested.
	lines := []string{fmt.Sprintf("%s  %s", sum, ArchiveName(version))}

	named := append([]string(nil), assets...)
	sort.Strings(named)
	seen := map[string]bool{ArchiveName(version): true}

	for _, path := range named {
		name := filepath.Base(path)
		// Release assets are flat, so two files with one basename would publish
		// as one and the checksums would describe whichever won.
		if seen[name] {
			return Result{}, fmt.Errorf("two assets are both called %q", name)
		}
		seen[name] = true

		assetSum, err := sha256Of(path)
		if err != nil {
			return Result{}, err
		}
		lines = append(lines, fmt.Sprintf("%s  %s", assetSum, name))
	}

	sumsPath := filepath.Join(outDir, SumsName)
	if err := os.WriteFile(sumsPath, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		return Result{}, fmt.Errorf("writing %s: %w", sumsPath, err)
	}

	return Result{Archive: archivePath, Sums: sumsPath, SHA256: sum}, nil
}

// sha256Of hashes a file that was built elsewhere — a cross-compiled binary,
// which this package does not produce and has no business producing.
func sha256Of(path string) (string, error) {
	handle, err := os.Open(path)
	if err != nil {
		return "", fmt.Errorf("reading asset %s: %w", path, err)
	}
	defer handle.Close()

	digest := sha256.New()
	if _, err := io.Copy(digest, handle); err != nil {
		return "", fmt.Errorf("reading asset %s: %w", path, err)
	}
	return hex.EncodeToString(digest.Sum(nil)), nil
}

// writeTree adds the runtime entries, in a fixed order.
func writeTree(archive *tar.Writer, tree, version string) error {
	prefix := Prefix(version)
	written := map[string]bool{}

	for _, entry := range install.RuntimeEntries {
		source := filepath.Join(tree, entry)
		if _, err := os.Lstat(source); errors.Is(err, os.ErrNotExist) {
			// Not every tree has every optional entry. What a tree must have is
			// checked when a source is prepared, not here.
			continue
		} else if err != nil {
			return fmt.Errorf("looking at %s: %w", source, err)
		}

		// An entry may name a file inside a directory that is not itself an
		// entry — doc/ ships two of its files and none of the rest. Extractors
		// mostly invent the missing parent; an archive that says what it holds
		// does not ask them to.
		if err := addParents(archive, entry, prefix, written); err != nil {
			return err
		}

		if err := add(archive, tree, entry, prefix); err != nil {
			return err
		}
	}

	return nil
}

// addParents writes a header for every directory above an entry that has not
// been written yet, outermost first, so the archive is ordered the way it is
// laid out.
func addParents(archive *tar.Writer, entry, prefix string, written map[string]bool) error {
	parent := filepath.Dir(entry)
	if parent == "." || parent == string(filepath.Separator) || written[parent] {
		return nil
	}

	if err := addParents(archive, parent, prefix, written); err != nil {
		return err
	}
	if err := addDir(archive, path.Join(prefix, filepath.ToSlash(parent))); err != nil {
		return err
	}

	written[parent] = true
	return nil
}

// addDir writes one directory header. Directories carry no bytes, so this is
// the whole of what a directory is in an archive.
func addDir(archive *tar.Writer, name string) error {
	header := &tar.Header{
		Typeflag: tar.TypeDir,
		Name:     name + "/",
		Mode:     0o755,
		ModTime:  stamp,
		Format:   tar.FormatPAX,
	}
	if err := archive.WriteHeader(header); err != nil {
		return fmt.Errorf("writing %s: %w", name, err)
	}
	return nil
}

// add walks one entry, depth first and in name order.
func add(archive *tar.Writer, tree, relative, prefix string) error {
	source := filepath.Join(tree, relative)

	info, err := os.Lstat(source)
	if err != nil {
		return fmt.Errorf("looking at %s: %w", source, err)
	}

	// The same rule the extractor will apply, and the same one staging applies:
	// a configuration tree is files and directories. Refusing here means the
	// archive cannot carry something the installer would have to decide about.
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("%s is a symlink, and a release archive carries files and directories only", source)
	}

	// Forward slashes, always: a tar entry is a path in an archive, not a path
	// on the machine that built it.
	name := path.Join(prefix, filepath.ToSlash(relative))

	switch {
	case info.IsDir():
		if err := addDir(archive, name); err != nil {
			return err
		}

		entries, err := os.ReadDir(source)
		if err != nil {
			return fmt.Errorf("reading %s: %w", source, err)
		}
		names := make([]string, 0, len(entries))
		for _, child := range entries {
			names = append(names, child.Name())
		}
		// Sorted, so the archive is the same every time it is built.
		sort.Strings(names)

		for _, child := range names {
			if err := add(archive, tree, filepath.Join(relative, child), prefix); err != nil {
				return err
			}
		}
		return nil

	case info.Mode().IsRegular():
		mode := int64(0o644)
		if info.Mode().Perm()&0o111 != 0 {
			mode = 0o755
		}

		header := &tar.Header{
			Typeflag: tar.TypeReg,
			Name:     name,
			Size:     info.Size(),
			Mode:     mode,
			ModTime:  stamp,
			Format:   tar.FormatPAX,
			// Deliberately nobody: an archive should not carry the account that
			// happened to build it, and nothing unpacking this may honour it.
			Uid: 0, Gid: 0, Uname: "", Gname: "",
		}
		if err := archive.WriteHeader(header); err != nil {
			return fmt.Errorf("writing %s: %w", name, err)
		}

		contents, err := os.Open(source)
		if err != nil {
			return fmt.Errorf("reading %s: %w", source, err)
		}
		defer contents.Close()

		if _, err := io.Copy(archive, contents); err != nil {
			return fmt.Errorf("copying %s: %w", source, err)
		}
		return nil

	default:
		return fmt.Errorf("%s is neither a file nor a directory", source)
	}
}

// ReadSums parses a SHA256SUMS file into checksums by file name, in the format
// `sha256sum` writes. Nothing else is accepted: a line this cannot parse is one
// whose meaning would have to be guessed at, in a file whose job is to be
// unambiguous.
func ReadSums(contents []byte) (map[string]string, error) {
	sums := map[string]string{}

	for number, line := range strings.Split(string(contents), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}

		digest, name, found := strings.Cut(line, "  ")
		if !found {
			return nil, fmt.Errorf("line %d of %s is not `<sha256>  <name>`", number+1, SumsName)
		}
		if len(digest) != sha256.Size*2 {
			return nil, fmt.Errorf("line %d of %s does not start with a sha256 digest", number+1, SumsName)
		}
		if _, err := hex.DecodeString(digest); err != nil {
			return nil, fmt.Errorf("line %d of %s does not start with a sha256 digest", number+1, SumsName)
		}

		clean := strings.TrimSpace(name)

		// One line per name. A file that lists an asset twice does not describe
		// one release unambiguously, and taking either entry would make its
		// meaning depend on the order the lines happen to be in — measured: with
		// two contradictory digests for the archive, the honest one first was
		// refused and the honest one last was accepted.
		if _, twice := sums[clean]; twice {
			return nil, fmt.Errorf("%s lists %s more than once", SumsName, clean)
		}
		sums[clean] = digest
	}

	if len(sums) == 0 {
		return nil, fmt.Errorf("%s lists nothing", SumsName)
	}
	return sums, nil
}

// Attribution is the commit an archive can honestly claim to have been built
// from. A release says "this was built from commit X", and both that and the tag
// are false if the runtime files differ from what X contains — not hypothetical:
// this was written after an archive was built from a tree whose lazy-lock.json
// had been changed by a `:Lazy sync` and never committed.
type Attribution struct {
	// Commit is the SHA the tree is checked out at.
	Commit string

	// Dirty are the runtime files that differ from it. Only runtime files: a
	// modified README of the maintainer's own notes does not make an archive
	// unattributable, because it is not in the archive.
	Dirty []string
}

// Attribute asks git what the tree is.
//
// An error means the question cannot be answered — no git, or not a checkout —
// and a release that cannot say where it came from is not a release.
func Attribute(tree string) (Attribution, error) {
	commit, err := git(tree, "rev-parse", "HEAD")
	if err != nil {
		return Attribution{}, fmt.Errorf("asking git what %s is checked out at: %w", tree, err)
	}

	// Only the entries that end up in the archive, and `--` so a path that
	// happens to look like a revision is still read as a path.
	args := append([]string{"status", "--porcelain", "--"}, install.RuntimeEntries...)
	status, err := git(tree, args...)
	if err != nil {
		return Attribution{}, fmt.Errorf("asking git what has changed in %s: %w", tree, err)
	}

	attribution := Attribution{Commit: strings.TrimSpace(commit)}
	for _, line := range strings.Split(status, "\n") {
		if trimmed := strings.TrimSpace(line); trimmed != "" {
			attribution.Dirty = append(attribution.Dirty, trimmed)
		}
	}
	return attribution, nil
}

func git(tree string, args ...string) (string, error) {
	command := exec.Command("git", append([]string{"-C", tree}, args...)...)
	output, err := command.Output()
	if err != nil {
		var exit *exec.ExitError
		if errors.As(err, &exit) && len(exit.Stderr) > 0 {
			return "", fmt.Errorf("%w: %s", err, strings.TrimSpace(string(exit.Stderr)))
		}
		return "", err
	}
	return string(output), nil
}
