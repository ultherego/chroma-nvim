package install

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// LocalSource installs from a checkout instead of a release.
//
// Developer-only, and the rule it exists under is the one at the top of
// cli/DESIGN.md: the CLI never installs `main`. A checkout is where work
// happens and is allowed to be broken. This exists so the install engine can be
// built and exercised end to end before there is a release to fetch — not so
// that anybody can install from a working tree.
type LocalSource struct {
	Root string
}

// Prepare checks that the tree is a Chroma tree and hands it over unchanged.
//
// Nothing is copied here. Staging copies it later, once the target is known,
// and doing it here would mean copying a tree the plan might never be allowed
// to place.
func (s LocalSource) Prepare(_ context.Context) (PreparedSource, error) {
	root := s.Root

	// Absolute first: every check below, and every path derived from this
	// later, resolves against the working directory otherwise — and the
	// installer is going to change directories' contents.
	if !filepath.IsAbs(root) {
		return PreparedSource{}, fmt.Errorf("--source-tree %q is not an absolute path", root)
	}
	root = filepath.Clean(root)

	info, err := os.Stat(root)
	if err != nil {
		return PreparedSource{}, fmt.Errorf("reading %s: %w", root, err)
	}
	if !info.IsDir() {
		return PreparedSource{}, fmt.Errorf("%s is not a directory", root)
	}

	// What makes a tree a Chroma tree, in the order somebody would notice it is
	// missing. lazy-lock.json is on the list because a tree without it installs
	// plugins at whatever their branches point at today, which is precisely the
	// reproducibility this project keeps a lockfile for.
	for _, required := range []struct {
		path string
		why  string
	}{
		{"init.lua", "there is nothing for Neovim to load"},
		{"components", "there is no component contract"},
		{"lazy-lock.json", "plugin versions would not be pinned"},
		// The second contract between a release and this CLI, and the one that
		// is easiest to forget exists. The installer drives
		// `require("chroma.bootstrap")` in the tree it places, so a release
		// without that module cannot be installed by this CLI — and finding
		// that out belongs here, before anything has been moved, rather than
		// halfway through a transaction that then has to be rolled back.
		{filepath.Join("lua", "chroma", "bootstrap.lua"), "the installer would have no way to bootstrap it"},
	} {
		if _, err := os.Stat(filepath.Join(root, required.path)); err != nil {
			return PreparedSource{}, fmt.Errorf("%s has no %s, so %s", root, required.path, required.why)
		}
	}

	// The same reader the editor uses, so a tree this accepts is a tree that
	// will resolve once it is placed. Refusing here costs a message; refusing
	// after placement costs a rollback.
	set, problems, err := component.Load(filepath.Join(root, "components"))
	if err != nil {
		return PreparedSource{}, fmt.Errorf("reading the component contract in %s: %w", root, err)
	}
	if len(problems) > 0 {
		return PreparedSource{}, fmt.Errorf("the component contract in %s does not read: %s", root, strings.Join(problems, "; "))
	}
	if problems := set.ResolveProblems(); len(problems) > 0 {
		return PreparedSource{}, fmt.Errorf("the component contract in %s does not resolve: %s", root, strings.Join(problems, "; "))
	}
	if set[coreID] == nil {
		return PreparedSource{}, fmt.Errorf("the component contract in %s declares no %q", root, coreID)
	}

	return PreparedSource{
		Root: root,
		// Deliberately unversioned: see PreparedSource.Version.
		Version:  "",
		Contract: component.Contract,
		Cleanup:  func() error { return nil },
	}, nil
}

// coreID is the component every other component requires. Named here rather
// than imported from the state package, which spells it for a different reason.
const coreID = "core"

// RefuseSourceInsideTarget rejects installing a tree onto itself, or onto
// anything containing it.
//
// Not string equality. The failure worth preventing is broader: staging copies
// the source while placement replaces the target, so a source that lives inside
// the target — or a target inside the source — means one operation reading what
// the other is moving. The obvious case is a developer whose checkout is
// symlinked as their configuration, which is exactly how this repository is set
// up on the machine it was written on.
func RefuseSourceInsideTarget(source string, paths Paths) error {
	source, err := resolve(source)
	if err != nil {
		return err
	}
	target, err := resolve(paths.ConfigDir)
	if err != nil {
		return err
	}

	switch {
	case source == target:
		return fmt.Errorf("the source tree and the installation target are both %s", target)
	case within(source, target):
		return fmt.Errorf("the source tree %s is inside the installation target %s", source, target)
	case within(target, source):
		return fmt.Errorf("the installation target %s is inside the source tree %s", target, source)
	}
	return nil
}

// resolve follows symlinks where it can. A target that does not exist yet is
// the normal case for a first install, so a path that cannot be resolved is
// cleaned and used as it is.
func resolve(path string) (string, error) {
	if !filepath.IsAbs(path) {
		return "", fmt.Errorf("%q is not an absolute path", path)
	}
	if real, err := filepath.EvalSymlinks(path); err == nil {
		return real, nil
	}
	return filepath.Clean(path), nil
}

// within reports whether inner is under outer. Both are already absolute and
// cleaned, so this is a path-component comparison rather than a prefix test:
// /a/bc is not inside /a/b.
func within(inner, outer string) bool {
	rel, err := filepath.Rel(outer, inner)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}
