package plan

import (
	"bytes"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// A contract built for the occasion, so these cases do not change meaning when
// the shipped one does.
func fixture() component.Set {
	return component.Set{
		"core": {ID: "core", Name: "Core", Tools: component.Tools{
			Required:    []component.Tool{{ID: "git", Reason: "plugins"}},
			Recommended: []component.Tool{{ID: "fzf", Reason: "pickers"}},
		}},
		"terraform": {ID: "terraform", Name: "Terraform", Requires: []string{"core"}, Tools: component.Tools{
			Required:    []component.Tool{{Any: []string{"terraform", "tofu"}, Reason: "the runner"}},
			Recommended: []component.Tool{{ID: "terragrunt", Reason: "stacks"}},
		}},
		"kubernetes": {ID: "kubernetes", Name: "Kubernetes", Requires: []string{"core"}, Tools: component.Tools{
			Required:    []component.Tool{{ID: "kubectl", Reason: "views"}},
			Recommended: []component.Tool{{ID: "helm", Reason: "charts"}},
		}},
	}
}

func has(names ...string) Lookup {
	set := map[string]bool{}
	for _, name := range names {
		set[name] = true
	}
	return func(name string) bool { return set[name] }
}

// The resolver's whole job, from the guidance: asking for Terraform gets Core
// whether or not the user thought of it.
func TestDependenciesArePulledIn(t *testing.T) {
	p := Build(fixture(), []string{"terraform"}, has("git", "terraform"))

	if got := strings.Join(p.Components, ","); got != "core,terraform" {
		t.Errorf("components = %q, want core,terraform", got)
	}
	if got := strings.Join(p.Added, ","); got != "core" {
		t.Errorf("added = %q, want core", got)
	}
}

func TestAskingForADependencyDirectlyIsNotAnAddition(t *testing.T) {
	p := Build(fixture(), []string{"core", "terraform"}, has("git", "terraform"))

	if len(p.Added) != 0 {
		t.Errorf("added = %v, want none: both were asked for by name", p.Added)
	}
}

// Silently installing less than was asked for is how somebody spends an evening
// debugging a component that was never enabled.
func TestUnknownComponentIsReported(t *testing.T) {
	p := Build(fixture(), []string{"terraform", "vault"}, has("git", "terraform"))

	if got := strings.Join(p.Unknown, ","); got != "vault" {
		t.Errorf("unknown = %q, want vault", got)
	}
	if !contains(p.Components, "terraform") {
		t.Error("the known component was dropped along with the unknown one")
	}
}

// Complete() is about Chroma's own tooling only. Without git there are no
// plugins and there is no installation.
func TestMissingChromaToolMakesThePlanIncomplete(t *testing.T) {
	if Build(fixture(), []string{"terraform"}, has("git", "tofu")).Complete() != true {
		t.Error("git is there, so the plan is complete")
	}

	if Build(fixture(), []string{"terraform"}, has("tofu")).Complete() {
		t.Error("a plan with no git is not complete: lazy.nvim cannot clone")
	}
}

// The decision this reflects: choosing the terraform component asks for
// Chroma's Terraform features, not for a terraform binary. An empty machine
// installs a complete Chroma, and the features say what they need when used.
func TestMissingExternalToolDoesNotMakeThePlanIncomplete(t *testing.T) {
	p := Build(fixture(), []string{"terraform"}, has("git"))

	if !p.Complete() {
		t.Error("neither terraform nor tofu is on this machine, and neither is Chroma's to install")
	}

	external := p.External()
	if len(external) == 0 {
		t.Fatal("the terraform tools are not reported as external at all")
	}
	for _, tool := range external {
		if tool.Component == "core" {
			t.Errorf("%v came from core and is not external", tool.Names)
		}
	}
}

// And core's own tools are never external, whichever component pulled core in.
func TestCoreToolsAreNotExternal(t *testing.T) {
	for _, tool := range Build(fixture(), []string{"terraform"}, has()).Tools {
		if tool.Names[0] == "git" && tool.External {
			t.Error("git is marked external; it is Chroma's own requirement")
		}
	}
}

// A recommended tool missing is not what Complete() is about, even when it is
// one of Chroma's own: the configuration works without it, and treating the two
// the same would make every plan on a fresh machine look broken.
func TestMissingRecommendedToolDoesNotMakeItIncomplete(t *testing.T) {
	p := Build(fixture(), []string{"core"}, has("git"))

	fzf := false
	for _, tool := range p.Tools {
		if tool.Names[0] == "fzf" {
			fzf = true
			if tool.External || tool.Level != "recommended" || tool.Present {
				t.Fatalf("fzf = %+v; this test needs core's own absent recommended tool", tool)
			}
		}
	}
	if !fzf {
		t.Fatal("fzf is not in the plan, so this proves nothing")
	}

	if !p.Complete() {
		t.Error("only a recommended tool is missing")
	}
}

func TestToolsAreListedOnce(t *testing.T) {
	p := Build(fixture(), []string{"terraform", "kubernetes"}, has("git"))

	count := 0
	for _, tool := range p.Tools {
		if tool.Names[0] == "git" {
			count++
		}
	}
	if count != 1 {
		t.Errorf("git appears %d times; both components reach core", count)
	}
}

// One component recommends a tool, another cannot work without it. The stricter
// level has to win, or a plan reports as complete while something required is
// missing. Verified by mutation: removing the rule used to break nothing,
// because the fixture claimed a conflict it did not contain.
func TestRequiredBeatsRecommended(t *testing.T) {
	// Components are processed in sorted order, so the one that only recommends
	// has to sort first — otherwise the required level is set by the first writer
	// and the branch that raises it never runs. That is what made the first
	// version of this test pass with the rule deleted.
	// The component that only recommends has to sort first, and the one that
	// requires has to be `core` — otherwise the tool is external and the last
	// assertion below cannot tell the rule from its absence.
	set := component.Set{
		"a-recommends": {ID: "a-recommends", Tools: component.Tools{
			Recommended: []component.Tool{{ID: "terragrunt", Reason: "nice to have here"}},
		}},
		"core": {ID: "core", Tools: component.Tools{
			Required: []component.Tool{{ID: "terragrunt", Reason: "cannot work without it here"}},
		}},
	}

	p := Build(set, []string{"a-recommends", "core"}, has())

	var found *Tool
	for i := range p.Tools {
		if p.Tools[i].Names[0] == "terragrunt" {
			if found != nil {
				t.Fatal("terragrunt is listed twice")
			}
			found = &p.Tools[i]
		}
	}
	if found == nil {
		t.Fatal("terragrunt is not in the plan at all")
	}
	if found.Level != "required" {
		t.Errorf("level = %q, want required: the other component cannot work without it", found.Level)
	}

	// And the consequence that matters: a missing tool at the stricter level
	// makes the plan incomplete.
	if p.Complete() {
		t.Error("terragrunt is required and absent, so the plan is not complete")
	}
}

// The other direction: required first, recommended second, must not downgrade.
func TestRecommendedDoesNotWeakenRequired(t *testing.T) {
	set := component.Set{
		"a-requires": {ID: "a-requires", Tools: component.Tools{
			Required: []component.Tool{{ID: "terragrunt", Reason: "cannot work without it"}},
		}},
		"b-recommends": {ID: "b-recommends", Tools: component.Tools{
			Recommended: []component.Tool{{ID: "terragrunt", Reason: "nice to have"}},
		}},
	}

	p := Build(set, []string{"a-requires", "b-recommends"}, has())
	if len(p.Tools) != 1 {
		t.Fatalf("tools = %v, want one entry", p.Tools)
	}
	if p.Tools[0].Level != "required" {
		t.Errorf("level = %q, want required", p.Tools[0].Level)
	}
}

func TestRenderNamesWhatIsMissing(t *testing.T) {
	var buffer bytes.Buffer
	Build(fixture(), []string{"terraform"}, has("git")).Render(&buffer)
	out := buffer.String()

	for _, want := range []string{"core, terraform", "pulled in as a dependency", "fzf (recommended)"} {
		if !strings.Contains(out, want) {
			t.Errorf("plan does not mention %q:\n%s", want, out)
		}
	}
}

// The user's own tools are named but not counted, and the plan says which of
// the two it is doing — otherwise the line reads as a checklist to satisfy
// before installing, which is exactly what it is not.
func TestRenderNamesExternalToolsWithoutCountingThem(t *testing.T) {
	var buffer bytes.Buffer
	Build(fixture(), []string{"terraform"}, has("git")).Render(&buffer)
	out := buffer.String()

	for _, want := range []string{"terraform/tofu", "does not install these"} {
		if !strings.Contains(out, want) {
			t.Errorf("plan does not mention %q:\n%s", want, out)
		}
	}
	// Which means it must not appear under Missing, where the exit code lives.
	missing := out[strings.Index(out, "Missing"):]
	if cut := strings.Index(missing, "External"); cut >= 0 {
		missing = missing[:cut]
	}
	if strings.Contains(missing, "terraform") {
		t.Errorf("an external tool is reported as missing:\n%s", out)
	}
}

// A plan that would install nothing said "Missing nothing", which is true and
// reads as success. The exit code disagreed with the text.
func TestRenderSaysWhenNothingWouldBeInstalled(t *testing.T) {
	var buffer bytes.Buffer
	Build(fixture(), []string{"vault"}, has()).Render(&buffer)
	out := buffer.String()

	if !strings.Contains(out, "nothing would be installed") {
		t.Errorf("an empty plan should say so:\n%s", out)
	}
	if strings.Contains(out, "Missing       nothing") {
		t.Errorf("an empty plan should not report a clean tool list:\n%s", out)
	}
}

func TestRenderSaysWhenNothingIsMissing(t *testing.T) {
	var buffer bytes.Buffer
	Build(fixture(), []string{"core"}, has("git", "fzf")).Render(&buffer)

	if !strings.Contains(buffer.String(), "Missing       nothing") {
		t.Errorf("a complete plan should say so:\n%s", buffer.String())
	}
}

func contains(list []string, want string) bool {
	for _, one := range list {
		if one == want {
			return true
		}
	}
	return false
}
