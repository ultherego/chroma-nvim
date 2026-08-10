package install

import (
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// RuntimeEntries is the configuration, and nothing else.
//
// One definition, because two consumers need exactly the same answer: copying a
// developer checkout into staging, and building the release archive. A list
// that existed twice would eventually ship a tree that installs differently
// from the one that was tested.
//
// In, because Neovim reads them: init.lua, lua/, after/, components/ — the
// contract is read at runtime, not baked in — doc/ for `:help`, and
// lazy-lock.json, without which plugin versions are whatever the branches point
// at today. README, LICENSE and the asset it references are in because somebody
// looking at the installed directory should be able to tell what it is.
//
// Out: cli/ is the installer, not the configuration; tests/ and .github/ are
// how it is developed; CONTRACT.md, DECISIONS.md and audit.md are how it is
// governed; selene.toml and stylua.toml configure tools no user runs. And .git
// is out for a reason worth stating: an installed configuration that is a
// checkout invites `git pull` on top of a managed installation, which is a way
// to arrive at a version no install state describes.
var RuntimeEntries = []string{
	"init.lua",
	"lua",
	"after",
	"components",
	"doc",
	"lazy-lock.json",
	"README.md",
	"LICENSE",
	"assets",
}

// now is the clock, replaced in tests so a backup name is predictable.
var now = func() time.Time { return time.Now().UTC() }

// CheckTarget decides whether an installation may proceed, and whether it has
// to back something up first.
//
// The three answers are different on purpose. An empty target is an ordinary
// install. A target this CLI installed is an update, and pretending otherwise
// would mean replacing a tree while its install state still describes the old
// one. A target that exists and was not installed by this CLI is somebody
// else's directory: for the default installation that is expected — it is
// Neovim's own — and the backup is what makes taking it over safe, but a
// directory sitting under our own appname that we did not put there is a
// surprise, and surprises are not something to overwrite.
func CheckTarget(paths Paths) (needsBackup bool, err error) {
	// The default installation is Neovim's own, so every one of Neovim's
	// directories is somebody else's until proved otherwise — and the answer
	// does not depend on whether there is a configuration in the first of them.
	//
	// It used to. `~/.config/nvim` missing returned "nothing to back up", and
	// somebody who had deleted their init.lua but still had years of plugins in
	// `~/.local/share/nvim` got them bootstrapped into and then removed as
	// Chroma's own. Which directories are actually there is Borrow's question,
	// and it skips the ones that are not.
	if _, err := os.Stat(paths.ConfigDir); errors.Is(err, os.ErrNotExist) {
		return paths.AppName == "", nil
	} else if err != nil {
		return false, fmt.Errorf("looking at %s: %w", paths.ConfigDir, err)
	}

	if _, err := os.Stat(paths.InstallState); err == nil {
		return false, fmt.Errorf("%s is already a Chroma installation; use `chroma update` to replace it", paths.ConfigDir)
	} else if !errors.Is(err, os.ErrNotExist) {
		return false, fmt.Errorf("looking at %s: %w", paths.InstallState, err)
	}

	if paths.AppName == "" {
		return true, nil
	}

	return false, fmt.Errorf("%s exists and no Chroma installation is recorded for it; move it aside first", paths.ConfigDir)
}

// StageSource copies the prepared tree to a sibling of the target.
//
// A sibling, so that the rename which places it cannot cross a filesystem — a
// cross-device rename is a copy, and a copy is not atomic. Copied rather than
// symlinked, so that what gets placed is a tree of its own: a symlink would
// leave the installation pointing at a developer's working copy, which is the
// thing `--source-tree` is least allowed to produce.
//
// Nothing touches the target until this has finished. A staging directory that
// failed halfway is a directory to delete; a target that failed halfway is
// somebody's editor.
func (tx *Transaction) StageSource(prepared PreparedSource, paths Paths) error {
	if err := os.MkdirAll(paths.BackupDir, 0o755); err != nil {
		return fmt.Errorf("creating %s: %w", paths.BackupDir, err)
	}

	pattern := fmt.Sprintf(".%s.chroma-stage-*", filepath.Base(paths.ConfigDir))
	stage, err := os.MkdirTemp(paths.BackupDir, pattern)
	if err != nil {
		return fmt.Errorf("creating a staging directory in %s: %w", paths.BackupDir, err)
	}
	tx.StageDir = stage

	for _, entry := range RuntimeEntries {
		from := filepath.Join(prepared.Root, entry)
		if _, err := os.Lstat(from); errors.Is(err, os.ErrNotExist) {
			// Not every release has every optional entry, and a missing README
			// is not a reason to refuse an installation. What a tree must have
			// was already checked when the source was prepared.
			continue
		} else if err != nil {
			return fmt.Errorf("looking at %s: %w", from, err)
		}

		if err := copyTree(from, filepath.Join(stage, entry)); err != nil {
			return err
		}
	}

	return nil
}

// RefuseSubstituted reports why a path the record names cannot be acted on.
//
// **A persisted path proves where Chroma once put something. It does not prove
// what is there now.** Between the record being written and this running,
// anything may have replaced the directory — measured, not imagined: with the
// kept generation replaced by a link, a rollback moved the link into place and
// rewrote the record, and an uninstall handed the link back as somebody's
// configuration and then deleted its own state.
//
// So the type is checked again, with Lstat, before any move that crosses an
// ownership boundary. A symbolic link is refused whatever is on the other end:
// following it would mean acting on an object Chroma never put there, and
// moving it would mean recording a link as a generation.
func RefuseSubstituted(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return fmt.Errorf("looking at %s: %w", path, err)
	}

	switch {
	case info.Mode()&os.ModeSymlink != 0:
		destination, readErr := os.Readlink(path)
		if readErr != nil {
			destination = "somewhere this cannot read"
		}
		return fmt.Errorf(
			"%s is a symbolic link to %s, not the directory Chroma recorded there.\nChroma will not move or remove what is on the other end of a link it did not make",
			path, destination)
	case !info.IsDir():
		return fmt.Errorf("%s is not a directory, so it is not the configuration Chroma recorded there", path)
	}
	return nil
}

// RestoreGeneration puts a kept generation back where a configuration lives.
//
// A rename, not a copy: the directory is the generation, and copying it would
// leave two of them with one record between them. The target has to be out of
// the way already, the same precondition Place has, because both of them are
// the same move onto the same path.
func (tx *Transaction) RestoreGeneration(from string, want Identity, paths Paths) error {
	if from == "" {
		return errors.New("no generation was named to restore")
	}
	// Shape, then identity. Both are needed and neither substitutes for the
	// other: the shape check says this is a directory rather than a link, and
	// the identity says it is the directory Chroma kept rather than one that
	// merely looks like it.
	if err := ProveIdentity(from, want, "generation"); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(from, "init.lua")); err != nil {
		return fmt.Errorf("%s is not a configuration that can be restored: %w", from, err)
	}

	if _, err := os.Lstat(paths.ConfigDir); err == nil {
		return fmt.Errorf("%s is still there; it has to be moved aside before a generation is restored", paths.ConfigDir)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("looking at %s: %w", paths.ConfigDir, err)
	}

	if err := os.Rename(from, paths.ConfigDir); err != nil {
		return describeRestoreFailure(from, paths.ConfigDir, err)
	}

	tx.Target = paths.ConfigDir
	tx.RestoredFrom = from
	tx.Restored = true
	return nil
}

// describeRestoreFailure turns a failed generation move into something worth
// reading.
//
// `invalid cross-device link` is true at the level of rename(2) and says almost
// nothing about what happened or what to do. It stays, as the last line, because
// it is the fact a diagnosis starts from — but above it goes what failed, why,
// and which two paths are on opposite sides of the problem.
//
// No instruction to move the directory by hand. `install.json` records where the
// generation is, so a directory moved behind Chroma's back produces a record
// that describes somewhere nothing is — which is a worse state than the refusal.
func describeRestoreFailure(from, to string, err error) error {
	if !errors.Is(err, syscall.EXDEV) {
		return fmt.Errorf("restoring %s as %s: %w", from, to, err)
	}

	return fmt.Errorf(`cannot restore the previous Chroma generation because it is on a different filesystem

Current:
  %s

Previous:
  %s

Chroma changes generations with an atomic rename and does not copy them across
filesystems: a copy has failure modes a rename does not, and a generation half
copied is worse than one not restored.

Cause: %w`, to, from, err)
}

// BackupTarget renames the existing configuration aside.
//
// A rename, not a copy: it is atomic, it cannot half-succeed, and it cannot run
// out of disk halfway through somebody's configuration. It goes to a sibling
// for the same reason staging does. If this cannot be done, the installation
// stops here — before anything has been placed, which is the only point at
// which stopping costs nothing.
func (tx *Transaction) BackupTarget(paths Paths) error {
	// A link is not moved aside, whatever it points at.
	//
	// Renaming one moves the link, so what would be recorded as the
	// configuration Chroma is holding — or as a generation — is a pointer to
	// somebody else's directory. Taking over a linked ~/.config/nvim produced
	// exactly that: an installation whose own uninstall then refused to hand a
	// link back, and so could never finish. Chroma cannot give back what it
	// cannot show it holds, so it does not take it in the first place.
	if err := RefuseSubstituted(paths.ConfigDir); err != nil {
		return fmt.Errorf("%w.\nMove or remove the link yourself if you want Chroma installed here", err)
	}

	stamp := now().Format("20060102T150405Z")
	backup := filepath.Join(paths.BackupDir, fmt.Sprintf("%s.chroma-backup-%s", filepath.Base(paths.ConfigDir), stamp))

	// A second install in the same second would otherwise rename over the first
	// one's backup, which is the one file that must not be lost.
	for suffix := 1; ; suffix++ {
		if _, err := os.Lstat(backup); errors.Is(err, os.ErrNotExist) {
			break
		} else if err != nil {
			return fmt.Errorf("looking at %s: %w", backup, err)
		}
		backup = filepath.Join(paths.BackupDir, fmt.Sprintf("%s.chroma-backup-%s.%d", filepath.Base(paths.ConfigDir), stamp, suffix))
	}

	if err := os.Rename(paths.ConfigDir, backup); err != nil {
		return fmt.Errorf("moving %s aside to %s: %w", paths.ConfigDir, backup, err)
	}

	// Where it came from, recorded here rather than by whatever happens next.
	// Rollback puts the backup back at Target, and until this line Target was
	// set only by Place — so a transaction that moved something aside and then
	// failed before placing anything had nowhere to put it back. Installing
	// never noticed, because Place always followed; uninstalling does, because
	// the step after this one is a restore that can fail.
	tx.Target = paths.ConfigDir
	tx.Backup = backup
	tx.BackupCreated = true

	// Read after the rename, from the path it now has: a rename keeps the
	// inode, so this is the identity of the very directory that was moved, and
	// reading it here rather than before means there is no window in which the
	// two could be of different things.
	identity, err := Identify(backup)
	if err != nil {
		return err
	}
	tx.BackupIdentity = identity
	return nil
}

// Place moves the staged tree onto the target, in one rename.
//
// The target must not exist by now: either it never did, or it has been renamed
// aside. There is deliberately no code path here that removes it — a delete
// followed by a rename is a window in which the user has no configuration at
// all, and the failure that lands in that window is unrecoverable.
func (tx *Transaction) Place(paths Paths) error {
	if tx.StageDir == "" {
		return fmt.Errorf("nothing has been staged for %s", paths.ConfigDir)
	}

	if _, err := os.Lstat(paths.ConfigDir); err == nil {
		return fmt.Errorf("%s is still there; it has to be moved aside before anything is placed", paths.ConfigDir)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("looking at %s: %w", paths.ConfigDir, err)
	}

	if err := os.Rename(tx.StageDir, paths.ConfigDir); err != nil {
		return fmt.Errorf("placing %s at %s: %w", tx.StageDir, paths.ConfigDir, err)
	}

	tx.Target = paths.ConfigDir
	tx.Placed = true
	tx.StageDir = ""
	return nil
}

// copyTree copies a file or directory, refusing anything that is neither.
//
// Symlinks are refused rather than followed or recreated. A configuration tree
// has no need of them, and both ways of handling one are worse than saying no:
// following it copies whatever it points at, which may be outside the source,
// and recreating it installs a link to a path that means something different on
// the target machine. The archive reader will refuse them for the same reason.
func copyTree(from, to string) error {
	info, err := os.Lstat(from)
	if err != nil {
		return fmt.Errorf("looking at %s: %w", from, err)
	}

	switch {
	case info.Mode()&os.ModeSymlink != 0:
		return fmt.Errorf("%s is a symlink, and a configuration tree is copied rather than linked", from)
	case info.IsDir():
		if err := os.MkdirAll(to, info.Mode().Perm()); err != nil {
			return fmt.Errorf("creating %s: %w", to, err)
		}
		entries, err := os.ReadDir(from)
		if err != nil {
			return fmt.Errorf("reading %s: %w", from, err)
		}
		for _, entry := range entries {
			if err := copyTree(filepath.Join(from, entry.Name()), filepath.Join(to, entry.Name())); err != nil {
				return err
			}
		}
		return nil
	case info.Mode().IsRegular():
		return copyFile(from, to, info.Mode().Perm())
	default:
		return fmt.Errorf("%s is neither a file nor a directory", from)
	}
}

func copyFile(from, to string, mode os.FileMode) error {
	source, err := os.Open(from)
	if err != nil {
		return fmt.Errorf("reading %s: %w", from, err)
	}
	defer source.Close()

	target, err := os.OpenFile(to, os.O_WRONLY|os.O_CREATE|os.O_EXCL, mode)
	if err != nil {
		return fmt.Errorf("creating %s: %w", to, err)
	}

	if _, err := io.Copy(target, source); err != nil {
		target.Close()
		return fmt.Errorf("copying %s to %s: %w", from, to, err)
	}
	if err := target.Close(); err != nil {
		return fmt.Errorf("closing %s: %w", to, err)
	}
	return nil
}
