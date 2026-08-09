package release

import (
	"archive/tar"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// maxEntrySize bounds one file out of an archive.
//
// The configuration's largest file is a logo measured in hundreds of kilobytes.
// This is far above anything a release contains and far below anything that
// would fill a disk, which is the point: an archive is a thing somebody else
// produced, and "unpack whatever it says" is not a policy.
//
// A variable rather than a constant so that the case which checks the limit can
// lower it: writing sixty-four megabytes to prove a refusal is a slow way to
// learn nothing extra.
var maxEntrySize int64 = 64 << 20

// Extract unpacks a release archive into `into`, and refuses everything else.
//
// The rules are deliberately narrow, because a configuration tree is files and
// directories and nothing more:
//
//   - every entry must be under the archive's own `chroma-nvim-<version>/`
//     prefix, which is stripped;
//   - no absolute paths, and nothing that escapes the destination after
//     cleaning — `../../etc/passwd` and `foo/../../bar` are the same refusal;
//   - regular files and directories only. Symlinks, hardlinks, devices, fifos
//     and sockets are refused rather than skipped, because skipping them
//     produces a tree that is quietly not what the archive described.
//
// Nothing is written outside `into`, and a refusal happens before the entry it
// refuses is created.
func Extract(archive io.Reader, into, prefix string) error {
	root, err := filepath.Abs(into)
	if err != nil {
		return fmt.Errorf("resolving %s: %w", into, err)
	}
	if err := os.MkdirAll(root, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", root, err)
	}

	compressed, err := gzip.NewReader(archive)
	if err != nil {
		return fmt.Errorf("reading the archive: %w", err)
	}
	defer compressed.Close()

	seen := 0
	reader := tar.NewReader(compressed)
	for {
		header, err := reader.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			return fmt.Errorf("reading the archive: %w", err)
		}

		target, err := destination(root, prefix, header.Name)
		if err != nil {
			return err
		}
		if target == "" {
			// The prefix directory itself.
			continue
		}

		switch header.Typeflag {
		case tar.TypeDir:
			if err := os.MkdirAll(target, 0o755); err != nil {
				return fmt.Errorf("creating %s: %w", target, err)
			}

		case tar.TypeReg:
			if header.Size > maxEntrySize {
				return fmt.Errorf("%s is %d bytes, which is more than a configuration file has any business being", header.Name, header.Size)
			}
			if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
				return fmt.Errorf("creating %s: %w", filepath.Dir(target), err)
			}

			mode := os.FileMode(0o644)
			if header.Mode&0o111 != 0 {
				mode = 0o755
			}

			file, err := os.OpenFile(target, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
			if err != nil {
				return fmt.Errorf("creating %s: %w", target, err)
			}
			// Bounded again while copying: the header's size is the archive's
			// claim about itself, not a fact.
			if _, err := io.Copy(file, io.LimitReader(reader, maxEntrySize+1)); err != nil {
				file.Close()
				return fmt.Errorf("writing %s: %w", target, err)
			}
			if err := file.Close(); err != nil {
				return fmt.Errorf("closing %s: %w", target, err)
			}
			seen++

		default:
			return fmt.Errorf("%s is neither a file nor a directory, and a release archive carries nothing else", header.Name)
		}
	}

	if seen == 0 {
		return fmt.Errorf("the archive contains no files under %s/", prefix)
	}
	return nil
}

// destination turns an entry name into a path inside root, or refuses.
//
// Returns an empty path for the prefix directory itself, which is the one entry
// with nothing to create.
func destination(root, prefix, name string) (string, error) {
	// Tar names are slash-separated regardless of the machine reading them.
	clean := filepath.ToSlash(filepath.Clean("/" + name))
	clean = strings.TrimPrefix(clean, "/")

	if name != clean && name != clean+"/" {
		// Cleaning changed it, which means it was not what it appeared to be:
		// an absolute path, a `..`, or a doubled separator.
		return "", fmt.Errorf("%q is not a plain relative path", name)
	}

	if clean == prefix {
		return "", nil
	}
	if !strings.HasPrefix(clean, prefix+"/") {
		return "", fmt.Errorf("%q is not under %s/, which is what this archive claims to be", name, prefix)
	}

	relative := strings.TrimPrefix(clean, prefix+"/")
	if relative == "" {
		return "", nil
	}

	target := filepath.Join(root, filepath.FromSlash(relative))

	// Belt and braces. The checks above should make this impossible; this is
	// the one that has to hold.
	if target != root && !strings.HasPrefix(target, root+string(filepath.Separator)) {
		return "", fmt.Errorf("%q would be written outside the destination", name)
	}
	return target, nil
}
