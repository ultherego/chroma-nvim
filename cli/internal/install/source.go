package install

import "context"

// PreparedSource is a Chroma tree sitting on this machine, ready to be placed.
//
// Everything past this point works from these fields and must not care how they
// were produced. That is the whole reason this type exists: the development
// path and the release path differ in where the bytes came from and in nothing
// else, so a stage that could tell them apart would be a stage that behaves
// differently in development from how it behaves for a user.
type PreparedSource struct {
	// Root is the directory holding init.lua, lua/ and components/.
	Root string

	// Version is the release this tree is. Empty means it is not a release —
	// only a source tree can be unversioned, and that is one of the reasons
	// --source-tree is developer-only: an installation with no version is one
	// that `update` has no way to reason about.
	Version string

	// Contract is the component contract version the tree declares. It is the
	// one this CLI understands, because a tree declaring any other is refused
	// while it is being read.
	Contract int

	// Cleanup releases whatever preparing this took — a temporary directory for
	// a downloaded release, nothing for a tree that was already here. Safe to
	// call more than once.
	Cleanup func() error
}

// Source produces a tree to install from.
type Source interface {
	Prepare(ctx context.Context) (PreparedSource, error)
}
