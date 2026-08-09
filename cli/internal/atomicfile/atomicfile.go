// Package atomicfile replaces a file, or does not touch it.
//
// Two documents are written by this CLI — the component selection and the
// install state — and both are read by something that decides what to do from
// them: an editor at startup, and this CLI when it comes to update or uninstall.
// A half-written one of either is worse than an old one.
//
// It lives on its own because it was about to exist twice. The same fifty lines
// in two packages is the arrangement where one of them quietly loses its
// directory flush.
package atomicfile

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Replace writes contents to path, atomically and durably.
//
// The steps are in this order for reasons that have each cost somebody
// something: the temporary file is a sibling so the rename cannot cross a
// filesystem; it is flushed before the rename, or the rename can land before
// the bytes; and the directory is flushed after, because a rename is atomic
// without being on the disk — the entry it changed is not durable until the
// directory holding it has been written.
//
// A failure at any point leaves the original file exactly as it was.
func Replace(path string, contents []byte, mode fs.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", dir, err)
	}

	temporary, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
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
	if err := temporary.Sync(); err != nil {
		return abandon(fmt.Errorf("syncing %s: %w", name, err))
	}
	if err := temporary.Close(); err != nil {
		return abandon(fmt.Errorf("closing %s: %w", name, err))
	}
	// CreateTemp makes the file 0600, which is not what either document wants.
	if err := os.Chmod(name, mode); err != nil {
		return abandon(fmt.Errorf("setting the mode of %s: %w", name, err))
	}
	if err := os.Rename(name, path); err != nil {
		return abandon(fmt.Errorf("replacing %s: %w", path, err))
	}

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
