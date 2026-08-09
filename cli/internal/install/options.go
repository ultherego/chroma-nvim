package install

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
