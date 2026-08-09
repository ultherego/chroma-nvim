package install

import (
	"fmt"
	"sort"
	"strings"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// Options is one installation as the user asked for it.
//
// It carries intent and nothing derived: which release, where it goes, what was
// selected, and how much the CLI is allowed to decide on its own. Everything
// that follows from it — paths, the plan, the transaction — is worked out from
// this one value, so that the interactive flow and the flag flow cannot diverge
// into two implementations of the same install.
type Options struct {
	// Version is the release to install: a tag, or "latest" to be resolved to a
	// tag before anything is shown to the user. A plan that says "latest" is a
	// plan that cannot be checked.
	Version string

	// SourceTree installs from a checkout instead of a release. Developer-only,
	// and it stays that way: `main` is where work happens and is allowed to be
	// broken, so no production path may reach it.
	SourceTree string

	// UseDefault takes over Neovim's own configuration directory, after the
	// existing one has been backed up.
	UseDefault bool

	// Selected are the optional components. `core` is implicit and is not a
	// legal member — naming it is refused rather than ignored, the same rule the
	// selection document itself keeps.
	//
	// Nil and empty are different, and the difference is the same one the
	// selection document makes between having no file and having `[]`: nil means
	// nobody said, empty means somebody said "core alone". A flag that was not
	// passed leaves this nil.
	Selected []string

	// Profile is a named set of components, resolved by the CLI. Mutually
	// exclusive with Selected.
	Profile string

	// NonInteractive means no questions: anything not answered by flags is
	// misuse rather than something to assume.
	NonInteractive bool

	// DryRun builds and shows the plan, and writes nothing at all.
	DryRun bool

	// AssumeYes accepts the final plan without asking. It does not fill in
	// components or agree to installing tools — it answers the last question,
	// not the ones before it.
	AssumeYes bool
}

// Validate checks what can be checked without a contract to check against.
//
// These are rules about the request rather than about the components in it, so
// they hold before anything has been fetched — which is where a misuse should
// be reported, rather than after a download.
func (o Options) Validate() error {
	if o.Profile != "" && o.Selected != nil {
		return fmt.Errorf("--profile and --components both name a selection; use one")
	}

	// Non-interactive means no questions, and "install nothing optional" is an
	// answer somebody has to give rather than one to assume on their behalf.
	// `--profile minimal` and `--components ''` both say it out loud.
	if o.NonInteractive && o.Profile == "" && o.Selected == nil {
		return fmt.Errorf("--non-interactive needs --components or --profile: there is nothing to fall back on")
	}

	if o.Version != "" && o.SourceTree != "" {
		return fmt.Errorf("--version and --source-tree name two different things to install; use one")
	}

	for _, id := range o.Selected {
		switch {
		case strings.TrimSpace(id) == "":
			return fmt.Errorf("--components has an empty component id")
		case id == coreID:
			return fmt.Errorf("--components names %q, which is always installed and is not a choice", coreID)
		}
	}

	seen := map[string]bool{}
	for _, id := range o.Selected {
		if seen[id] {
			return fmt.Errorf("--components names %q twice", id)
		}
		seen[id] = true
	}

	return nil
}

// Selection is the optional components this request comes to, checked against
// the contract that is about to be installed.
//
// Sorted, and without core: what comes back is exactly what belongs in the
// selection document, so the installer never has to reshape it on the way to
// being written.
func (o Options) Selection(set component.Set) ([]string, error) {
	if err := o.Validate(); err != nil {
		return nil, err
	}

	if o.Profile != "" {
		selected, err := ResolveProfile(o.Profile, set)
		if err != nil {
			return nil, err
		}
		sort.Strings(selected)
		return selected, nil
	}

	var unknown []string
	for _, id := range o.Selected {
		if set[id] == nil {
			unknown = append(unknown, id)
		}
	}
	if len(unknown) > 0 {
		return nil, fmt.Errorf("this release has no component %s", strings.Join(unknown, ", "))
	}

	selected := append([]string(nil), o.Selected...)
	sort.Strings(selected)
	if selected == nil {
		selected = []string{}
	}
	return selected, nil
}
