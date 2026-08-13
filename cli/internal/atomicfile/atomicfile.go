// Package atomicfile replaces a file, or does not touch it. Two documents are
// written by this CLI — the component selection and the install state — and both
// are read by something that decides what to do from them, so a half-written one
// is worse than an old one. Its own package because it was about to exist twice.
package atomicfile

import (
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
)

// Result says how far a replacement got, because the two failures are not the
// same event. Before the rename, the replacement did not happen and the old file
// is intact; after it, the new contents are already at the path and only their
// durability is in question.
//
// Measured, before this type existed: a record write that failed after its
// rename was reported as not written, so the update rolled the tree back to the
// generation the record no longer described.
type Result struct {
	// Replaced says the new contents are at the path.
	Replaced bool

	// Durable says the directory entry has been flushed. False with Replaced
	// true means the change is visible and might not survive a power cut.
	Durable bool
}

// Replace writes contents to path, atomically and durably. The order has cost
// somebody something at every step: the temporary file is a sibling so the
// rename cannot cross a filesystem; it is flushed before the rename, or the
// rename can land before the bytes; and the directory is flushed after, because
// a rename is atomic without being on the disk.
//
// The directory is opened *before* the rename, so the one failure that can be
// moved out of the post-commit window is moved out of it.
func Replace(path string, contents []byte, mode fs.FileMode) (Result, error) {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return Result{}, fmt.Errorf("creating %s: %w", dir, err)
	}

	// Opened here rather than after the rename: an open that fails is then a
	// failure of a replacement that has not happened.
	handle, err := os.Open(dir)
	if err != nil {
		return Result{}, fmt.Errorf("opening %s to flush it: %w", dir, err)
	}
	defer handle.Close()

	temporary, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return Result{}, fmt.Errorf("creating a temporary file in %s: %w", dir, err)
	}
	name := temporary.Name()

	abandon := func(cause error) (Result, error) {
		temporary.Close()
		os.Remove(name)
		return Result{}, cause
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

	// Everything past this line has already happened as far as anybody reading
	// the file is concerned.
	if err := os.Rename(name, path); err != nil {
		return abandon(fmt.Errorf("replacing %s: %w", path, err))
	}

	if err := hit(path); err != nil {
		return Result{Replaced: true}, fmt.Errorf("flushing %s: %w", dir, err)
	}
	if err := handle.Sync(); err != nil {
		return Result{Replaced: true}, fmt.Errorf("flushing %s: %w", dir, err)
	}

	return Result{Replaced: true, Durable: true}, nil
}

// afterRename stops a replacement between the rename and the directory flush.
// Nil everywhere except a test in this package: that window cannot be produced
// by permissions or a full disk, and it is the one where the file has already
// been replaced and the caller has not been told. Unexported, and it stays that
// way — a primitive does not carry a way to make itself fail in every binary
// that links it.
var afterRename func(path string) error

func hit(path string) error {
	if afterRename == nil {
		return nil
	}
	return afterRename(path)
}
