package install

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"syscall"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// This file is about one question: when Chroma is about to move, remove or hand
// back a directory, how does it know that directory is the one it thinks it is?
//
// Two answers were measured and both were wrong. The first was the path — an
// uninstall handed back whatever stood at `user_backup`, so an ordinary
// nvim-shaped directory put there afterwards was returned to somebody as their
// own configuration, and a rollback restored an ordinary directory put at the
// recorded generation's path as that generation. The second was the shape —
// `Lstat` proves a thing is a directory and not a link, which is worth having
// and is not identity.
//
// What is used instead is the device, inode and modification time the directory
// had at the moment it was taken. `rename` keeps all three, which is exactly the
// property needed: every move Chroma makes preserves the identity.
//
// The inode alone was tried and measured to be insufficient. It answers the
// copy: a `cp -a` of a directory has a different inode however carefully the
// contents are reproduced. It does not answer the substitution, because a
// filesystem may hand a newly created directory the inode of one just deleted at
// the same path — and on ext4 that is not a rare event but the normal one:
//
//	btrfs, tmpfs, overlayfs   0/40 rounds reused the inode
//	ext4 (the CI runner)     40/40 rounds reused the inode
//
// The substitution tests passed on a development machine and failed on CI for
// exactly that reason, which is the only reason this was found before release.
//
// The modification time closes it. A directory's own mtime is not changed by
// renaming it — only by changing what is in it — so it survives every move
// Chroma makes; and a directory created in place of a deleted one is created
// now, so its mtime is not the one that was recorded. Nanosecond resolution,
// taken from the same stat call, at no cost.
//
// This is also why there is no marker file inside the directory. A marker is
// content: `cp -a` copies it, so it would not answer the case the inode already
// answers, and it would mean writing into a directory Chroma has promised to
// give back untouched.
//
// This is not, and does not claim to be, a defence against the owner of the
// account editing install.json. See cli/DESIGN.md.

// Borrowable is one of Neovim's directories, and what it is called.
//
// Taking over `~/.config/nvim` is not taking over one directory. Neovim without
// NVIM_APPNAME also reads `~/.local/share/nvim`, `~/.local/state/nvim` and
// `~/.cache/nvim`, and a bootstrap writes plugins, packages and parsers into
// all three. Borrowing only the first is what destroyed a machine's plugins and
// undo history in the reproduction that led to this file.
type Borrowable struct {
	// Kind is what to call it when telling somebody what is about to happen.
	Kind string

	// Original is where it belongs.
	Original string
}

// Borrowable lists the directories an installation would take over, in the
// order they should be moved.
//
// Configuration first, because it is the one whose absence stops Neovim
// starting at all, and therefore the one whose failure should stop the
// installation earliest.
func (p Paths) Borrowable() []Borrowable {
	return []Borrowable{
		{Kind: "configuration", Original: p.ConfigDir},
		{Kind: "data", Original: p.DataDir},
		{Kind: "state", Original: p.StateDir},
		{Kind: "cache", Original: p.CacheDir},
	}
}

// Identity is what a directory was when Chroma took it.
type Identity struct {
	Device uint64
	Inode  uint64

	// Mtime is nanoseconds since the epoch. Together with the inode it
	// separates "the directory that was moved here" from "a directory created
	// here after that one was deleted", which the inode cannot do on its own.
	Mtime int64
}

// Identify reads the identity of the directory at a path.
//
// Lstat rather than Stat: the identity of a link is the link's, and a link is
// refused elsewhere anyway. Reading through it here would record the identity
// of somebody else's directory as Chroma's.
func Identify(path string) (Identity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return Identity{}, fmt.Errorf("looking at %s: %w", path, err)
	}
	return identityOf(info, path)
}

func identityOf(info fs.FileInfo, path string) (Identity, error) {
	// Every filesystem this runs on reports both. One that does not cannot be
	// asked the question this package needs answered, and the honest response
	// is to stop rather than to carry on with an identity of zero — which
	// would compare equal to every other unanswerable one.
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return Identity{}, fmt.Errorf("%s is on a filesystem that does not report a device and inode, so Chroma cannot prove what it is", path)
	}

	identity := Identity{
		Device: uint64(stat.Dev),
		Inode:  uint64(stat.Ino),
		Mtime:  stat.Mtim.Sec*1_000_000_000 + stat.Mtim.Nsec,
	}
	if identity.Device == 0 && identity.Inode == 0 {
		return Identity{}, fmt.Errorf("%s reports no device or inode, so Chroma cannot prove what it is", path)
	}
	return identity, nil
}

// ProveIdentity refuses unless the directory at a path is the one that was
// taken.
//
// Called before every move of a borrowed directory and before every restore of
// a generation. The refusal is deliberately not repairable: if what is at the
// path is not what Chroma recorded, then Chroma does not know where the real
// one went, and the two candidate actions — hand this back as somebody's
// configuration, or delete it as Chroma's — are both destructive and both
// wrong.
func ProveIdentity(path string, want Identity, what string) error {
	if err := RefuseSubstituted(path); err != nil {
		return err
	}

	got, err := Identify(path)
	if err != nil {
		return err
	}
	if got != want {
		return fmt.Errorf(
			"%s is not the %s Chroma recorded there: it was created after Chroma took it, or replaced since.\n"+
				"Chroma will not act on a directory it cannot show is the one it left. Move it aside yourself and look at what is there",
			path, what)
	}
	return nil
}

// Borrow moves every one of Neovim's directories that exists out of the way,
// and records what each was.
//
// Renames, not copies: atomic, unable to half-succeed, and unable to run out of
// disk in the middle of somebody's plugin tree. Each goes to a sibling of
// itself, so the move cannot cross a filesystem.
//
// All or nothing. A run that moves the configuration and then cannot move the
// data directory puts the configuration back before returning, because half a
// takeover is a Neovim that starts against a configuration and a plugin tree
// which were never meant to meet.
func (tx *Transaction) Borrow(paths Paths) error {
	for _, borrowable := range paths.Borrowable() {
		moved, err := tx.borrowOne(borrowable)
		if err != nil {
			// Undo only what this loop did. The caller's Rollback would do the
			// same, but a failure here happens before anything else in the
			// transaction has begun, and leaving the machine as it was found is
			// the whole reason this step comes first.
			return errors.Join(err, tx.giveBackBorrowed())
		}
		if moved {
			continue
		}
	}
	return nil
}

// borrowOne moves one directory aside, or reports that there was nothing there.
func (tx *Transaction) borrowOne(borrowable Borrowable) (bool, error) {
	info, err := os.Lstat(borrowable.Original)
	if errors.Is(err, os.ErrNotExist) {
		// Nothing to borrow and nothing owed back. A machine where Neovim has
		// never run has no data directory, and inventing an empty one to hand
		// back later would be Chroma leaving a directory somebody did not have.
		return false, nil
	} else if err != nil {
		return false, fmt.Errorf("looking at %s: %w", borrowable.Original, err)
	}

	// A link is not moved aside, whatever it points at.
	//
	// Renaming one moves the link, so what would be recorded as the directory
	// Chroma is holding is a pointer to somebody else's. Taking over a linked
	// ~/.config/nvim produced exactly that: an installation whose own uninstall
	// then refused to hand a link back, and so could never finish. Chroma
	// cannot give back what it cannot show it holds, so it does not take it.
	if info.Mode()&os.ModeSymlink != 0 {
		return false, fmt.Errorf(
			"%s is a link, and Chroma will not move or remove what is on the other end of a link it did not make.\n"+
				"Move or remove the link yourself if you want Chroma installed here", borrowable.Original)
	}
	if !info.IsDir() {
		return false, fmt.Errorf("%s is not a directory, and Chroma will not move it aside", borrowable.Original)
	}

	identity, err := identityOf(info, borrowable.Original)
	if err != nil {
		return false, err
	}

	backup, err := asideFrom(borrowable.Original)
	if err != nil {
		return false, err
	}

	if err := os.Rename(borrowable.Original, backup); err != nil {
		return false, fmt.Errorf("moving %s aside to %s: %w", borrowable.Original, backup, err)
	}

	tx.Borrowed = append(tx.Borrowed, installstate.Borrowed{
		Kind:     borrowable.Kind,
		Original: borrowable.Original,
		Backup:   backup,
		Device:   identity.Device,
		Inode:    identity.Inode,
		Mtime:    identity.Mtime,
		Handover: installstate.HandoverHeld,
	})
	return true, nil
}

// asideFrom picks an unused sibling path to move a directory to.
func asideFrom(original string) (string, error) {
	stamp := now().Format("20060102T150405Z")
	base := filepath.Join(filepath.Dir(original), filepath.Base(original)+".chroma-backup-"+stamp)

	// A second install in the same second would otherwise rename over the first
	// one's backup, which is the one directory that must not be lost.
	aside := base
	for suffix := 1; ; suffix++ {
		if _, err := os.Lstat(aside); errors.Is(err, os.ErrNotExist) {
			return aside, nil
		} else if err != nil {
			return "", fmt.Errorf("looking at %s: %w", aside, err)
		}
		aside = fmt.Sprintf("%s.%d", base, suffix)
	}
}

// giveBackBorrowed puts every directory this transaction moved aside back where
// it came from, and forgets the ones it managed to return.
//
// In reverse, so that a run which stops partway leaves the machine in a state
// its own next attempt can continue from rather than one it has to reason
// about. Each is proved before it is moved, for the same reason every other
// move is: the record says where, not what.
func (tx *Transaction) giveBackBorrowed() error {
	var problems []error
	kept := tx.Borrowed[:0]

	for index := len(tx.Borrowed) - 1; index >= 0; index-- {
		borrowed := tx.Borrowed[index]

		if err := ProveIdentity(borrowed.Backup, identityOfRecord(borrowed), borrowed.Kind+" Chroma moved aside"); err != nil {
			problems = append(problems, err)
			kept = append(kept, borrowed)
			continue
		}
		if err := os.Rename(borrowed.Backup, borrowed.Original); err != nil {
			problems = append(problems, fmt.Errorf("putting %s back as %s: %w", borrowed.Backup, borrowed.Original, err))
			kept = append(kept, borrowed)
			continue
		}
	}

	// Reversed twice is the order they were taken in, which is the order
	// anything reading this list expects.
	for left, right := 0, len(kept)-1; left < right; left, right = left+1, right-1 {
		kept[left], kept[right] = kept[right], kept[left]
	}
	tx.Borrowed = kept

	return errors.Join(problems...)
}

// identityOfRecord is what a borrowed directory was, as the record holds it.
func identityOfRecord(borrowed installstate.Borrowed) Identity {
	return Identity{Device: borrowed.Device, Inode: borrowed.Inode, Mtime: borrowed.Mtime}
}
