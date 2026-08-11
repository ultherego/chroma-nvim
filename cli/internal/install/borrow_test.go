package install

import (
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/installstate"
)

// borrowedNow describes a directory as borrowed, with the identity it actually
// has on disk right now. Written rather than hand-filled because a made-up
// device and inode would make every identity check in these tests pass or fail
// for the wrong reason.
func borrowedNow(t *testing.T, kind, original, backup string) installstate.Borrowed {
	t.Helper()

	identity, err := Identify(backup)
	if err != nil {
		t.Fatalf("Identify(%s): %v", backup, err)
	}
	return installstate.Borrowed{
		Kind:     kind,
		Original: original,
		Backup:   backup,
		Device:   identity.Device,
		Inode:    identity.Inode,
		Mtime:    identity.Mtime,
		Handover: installstate.HandoverHeld,
	}
}

// pendingHandover puts every borrowed directory into the state a kill inside
// the transfer leaves behind.
func pendingHandover(current installstate.State) installstate.State {
	updated := current
	updated.Borrowed = append([]installstate.Borrowed(nil), current.Borrowed...)
	for index := range updated.Borrowed {
		updated.Borrowed[index].Handover = installstate.HandoverPending
	}
	return updated
}

// handoverOf reads how far one borrowed directory has got.
func handoverOf(current installstate.State, kind string) installstate.Handover {
	for _, one := range current.Borrowed {
		if one.Kind == kind {
			return one.Handover
		}
	}
	return installstate.HandoverNone
}

// borrowedBackup is the path a borrowed directory is being held at.
func borrowedBackup(current installstate.State, kind string) string {
	for _, one := range current.Borrowed {
		if one.Kind == kind {
			return one.Backup
		}
	}
	return ""
}
