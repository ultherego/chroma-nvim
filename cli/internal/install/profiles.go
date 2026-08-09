package install

import (
	"fmt"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// Profiles are named selections, and they live here rather than in the
// component contract.
//
// A profile is an opinion about which components go together — "if you came for
// Kubernetes you probably want Helm" — and an opinion is not a fact about the
// product. The contract describes what a component is and what it needs; that
// is read by the editor, by this CLI, and by anything else that ever wants it.
// A profile is read by one installer, on one screen, once. The same split as
// tool versions and package names: the contract says what exists, the CLI
// decides how to present it.
//
// Sorted names only, and every id here is checked against the contract before
// use, so a profile naming a component that no longer exists fails loudly at
// plan time rather than silently installing less than it says.
var Profiles = map[string][]string{
	// Nothing optional. Not an empty profile by accident — the editor, and
	// nothing else, is a selection somebody makes on purpose.
	"minimal": {},

	"terraform":  {"terraform", "aws", "vault"},
	"kubernetes": {"kubernetes", "helm", "docker"},

	// Everything the contract declares, worked out from the contract rather
	// than listed here, so it cannot fall behind a new component.
	"everything": nil,
}

// ProfileNames are the profiles that can be asked for, in a stable order.
func ProfileNames() []string {
	names := make([]string, 0, len(Profiles))
	for name := range Profiles {
		names = append(names, name)
	}
	sort.Strings(names)
	return names
}

// ResolveProfile expands a profile into the optional components it selects.
//
// `core` never appears in the result. It is enabled always and is not a choice,
// which is the same rule the selection document keeps, and a profile that could
// name it would be a second place where that rule has to hold.
func ResolveProfile(name string, set component.Set) ([]string, error) {
	selected, known := Profiles[name]
	if !known {
		return nil, fmt.Errorf("unknown profile %q; the profiles are %s", name, strings.Join(ProfileNames(), ", "))
	}

	// "everything" is defined by the contract, not by this file.
	if name == "everything" {
		for _, id := range set.IDs() {
			if id != coreID {
				selected = append(selected, id)
			}
		}
		return selected, nil
	}

	// A profile is written by hand and the contract moves without it. A name
	// that no longer exists has to be loud here, because the alternative is an
	// installation that quietly contains less than the profile promised.
	var missing []string
	for _, id := range selected {
		if set[id] == nil {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		return nil, fmt.Errorf("profile %q names components this release does not have: %s", name, strings.Join(missing, ", "))
	}

	return append([]string(nil), selected...), nil
}
