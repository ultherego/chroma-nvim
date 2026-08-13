package install

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// This file answers one question: when Chroma is about to move, remove or hand
// back a directory, how does it know that directory is the one it thinks it is?
//
// Not the path, and not the shape — both were measured and both were wrong. What
// is used is the device, inode and modification time the directory had when it
// was taken, because `rename` keeps all three. The inode alone is insufficient:
// on ext4 a new directory gets the inode of one just deleted at the same path
// (40/40 rounds, against 0/40 on btrfs, tmpfs and overlayfs), and the mtime is
// what closes that. No marker file, because `cp -a` would copy it and because
// these directories are promised back untouched. See cli/DESIGN.md.

// Borrowable is one of Neovim's directories, and what it is called. Taking over
// `~/.config/nvim` is not taking over one directory: without NVIM_APPNAME Neovim
// also reads `~/.local/share/nvim`, `~/.local/state/nvim` and `~/.cache/nvim`,
// and borrowing only the first destroyed a machine's plugins and undo history.
type Borrowable struct {
	// Kind is what to call it when telling somebody what is about to happen.
	Kind string

	// Original is where it belongs.
	Original string
}

// Borrowable lists the directories an installation would take over, in the
// order they should be moved. Configuration first, because its absence stops
// Neovim starting at all, so its failure should stop the installation earliest.
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

	// Mtime is nanoseconds since the epoch. With the inode it separates "the
	// directory that was moved here" from "one created here afterwards".
	Mtime int64
}

// Identify reads the identity of the directory at a path. Lstat rather than
// Stat: reading through a link would record the identity of somebody else's
// directory as Chroma's.
func Identify(path string) (Identity, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return Identity{}, fmt.Errorf("looking at %s: %w", path, err)
	}
	return identityOf(info, path)
}

func identityOf(info fs.FileInfo, path string) (Identity, error) {
	// A filesystem that reports neither cannot be asked the question this
	// package needs answered, and an identity of zero would compare equal to
	// every other unanswerable one.
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return Identity{}, fmt.Errorf("%s is on a filesystem that does not report a device and inode, so Chroma cannot prove what it is", path)
	}

	identity := Identity{
		Device: uint64(stat.Dev),
		Inode:  uint64(stat.Ino),
		// From fs.FileInfo rather than the Stat_t beside it: the field is Mtim on
		// Linux and Mtimespec on Darwin, so reading it directly compiles on one
		// machine and nowhere else — which happened, and the cross-compile gate
		// caught it. ModTime is the same value, spelled one way everywhere.
		Mtime: info.ModTime().UnixNano(),
	}
	if identity.Device == 0 && identity.Inode == 0 {
		return Identity{}, fmt.Errorf("%s reports no device or inode, so Chroma cannot prove what it is", path)
	}
	return identity, nil
}

// ProveIdentity refuses unless the directory at a path is the one that was
// taken. Called before every move of a borrowed directory and every restore of
// a generation. Deliberately not repairable: if what is there is not what was
// recorded, Chroma does not know where the real one went, and both candidate
// actions are destructive.
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

// Borrow moves every one of Neovim's directories that exists out of the way and
// records what each was. Renames, not copies: atomic, unable to half-succeed,
// and each goes to a sibling of itself so the move cannot cross a filesystem.
//
// All or nothing — half a takeover is a Neovim starting against a configuration
// and a plugin tree that were never meant to meet.
func (tx *Transaction) Borrow(paths Paths) error {
	for _, borrowable := range paths.Borrowable() {
		moved, err := tx.borrowOne(borrowable)
		if err != nil {
			// Undo only what this loop did: a failure here happens before
			// anything else in the transaction has begun.
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
		// Nothing to borrow and nothing owed back. Inventing an empty directory
		// to hand back later would leave somebody one they never had.
		return false, nil
	} else if err != nil {
		return false, fmt.Errorf("looking at %s: %w", borrowable.Original, err)
	}

	// A link is not moved aside, whatever it points at: renaming one moves the
	// link, so what gets recorded as the directory Chroma holds is a pointer to
	// somebody else's. Measured — a linked ~/.config/nvim produced an
	// installation whose own uninstall could never finish.
	if info.Mode()&os.ModeSymlink != 0 {
		return false, fmt.Errorf(
			"%s is a link, and Chroma will not move or remove what is on the other end of a link it did not make.\n"+
				"Move or remove the link yourself if you want Chroma installed here", borrowable.Original)
	}
	if !info.IsDir() {
		return false, fmt.Errorf("%s is not a directory, and Chroma will not move it aside", borrowable.Original)
	}

	// Chroma's own directories are never borrowed, whatever the record says.
	// The record usually prevents this, but it can be deleted by hand — and
	// then the directory at Neovim's path is Chroma's from last time, and
	// borrowing it records Chroma's own files as "the state you had before
	// Chroma" while the real one is left with nothing pointing at it.
	//
	// Measured on a real machine: two generations of backups side by side, and
	// a later uninstall would have handed back the wrong one and orphaned
	// 800 MB of somebody's editor.
	if found := chromaLeftIt(borrowable.Original); found != "" {
		return false, fmt.Errorf(
			"%s is a directory an earlier Chroma left behind (%s), not a %s of yours.\n"+
				"Borrowing it would record Chroma's own files as what you had before Chroma, and orphan whatever is in the backup beside it.\n"+
				"Look at %s.chroma-backup-* — one of them is yours — then remove or move %s and install again",
			borrowable.Original, found, borrowable.Kind, borrowable.Original, borrowable.Original)
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

// chromaLeftIt names what marks a directory as one Chroma made, or "". Two
// marks, both things only this program writes: `install.json`, and a
// `logs/install-*.log`. Measured on a real machine, the second is what told
// Chroma's copy of a state directory apart from the user's, which had a shada
// and an `lsp.log` and no `logs/` at all.
//
// Deliberately narrow: a directory somebody else's plugin called `logs` is not
// evidence of anything.
func chromaLeftIt(dir string) string {
	if _, err := os.Lstat(filepath.Join(dir, "install.json")); err == nil {
		return "it holds install.json"
	}

	logs, err := os.ReadDir(filepath.Join(dir, "logs"))
	if err != nil {
		return ""
	}
	for _, entry := range logs {
		if strings.HasPrefix(entry.Name(), "install-") && strings.HasSuffix(entry.Name(), ".log") {
			return "it holds logs/" + entry.Name()
		}
	}

	return ""
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

// giveBackBorrowed puts every directory this transaction moved aside back, and
// forgets the ones it managed to return. In reverse, so a run that stops partway
// leaves a state its own next attempt can continue from. Each is proved before
// it is moved: the record says where, not what.
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

	// Reversed twice is the order they were taken in.
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
