// This file is the terminal version, and it runs only when there is a terminal.
// An enhancement on top of the printed questions beside it, not a replacement:
// both fill in the same Choices, and if this file were deleted the installer
// would still work everywhere.
//
// It deliberately does not use huh's accessible mode — see the note in line.go:
// its prompts cannot signal an error, so a closed pipe reads as an answer nobody
// gave.
package tui

import (
	"errors"
	"io"
	"strings"

	"charm.land/bubbles/v2/key"
	"charm.land/huh/v2"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
)

// onScreen is the adapter that asks with selectors somebody moves through.
func onScreen(what questions, set component.Set, in io.Reader, out io.Writer) (Choices, error) {
	chosen := Choices{UseDefault: what.takenOver}

	// Seeded, and separate from the returned value until the form has run: a
	// form that is cancelled must not leave a half-answer behind.
	takeover := what.takenOver
	selected := append([]string{}, what.current...)

	var fields []huh.Field
	if what.location {
		fields = append(fields, locationField(&takeover))
	}
	if what.components {
		optional := optionalIn(set)
		if len(optional) == 0 {
			chosen.Components = []string{}
		} else {
			fields = append(fields, componentsField(set, optional, &selected))
		}
	}

	if len(fields) == 0 {
		return chosen, nil
	}

	if what.location {
		welcome(out)
	}

	form := huh.NewForm(huh.NewGroup(fields...)).
		WithInput(in).
		WithOutput(out).
		WithKeyMap(wayOut()).
		WithTheme(huh.ThemeFunc(huh.ThemeCatppuccin))

	if err := form.Run(); err != nil {
		return Choices{}, translate(err)
	}

	chosen.UseDefault = takeover
	if what.components {
		// Empty rather than nil, always: "none of them" is an answer, and nil
		// means the question was never put.
		if selected == nil {
			selected = []string{}
		}
		chosen.Components = selected
	}
	return chosen, nil
}

// wayOut adds escape to the keys that leave without installing anything. The
// library binds only ctrl+c, and with no help text, so the form offered no
// visible way out — measured: escape on the placement selector did nothing and
// the run sat there until it was killed.
//
// The cost, stated because it is real: the form checks this before the field
// does, so escape no longer clears an active `/` filter. Backspace still does.
func wayOut() *huh.KeyMap {
	keys := huh.NewDefaultKeyMap()
	keys.Quit = key.NewBinding(key.WithKeys("ctrl+c", "esc"), key.WithHelp("esc", "cancel"))
	return keys
}

// locationField offers the two placements the installer actually supports.
//
// The second description is not decoration. Taking over Neovim's own directory
// is taking over four of them, and somebody agreeing to that should be told
// which — it used to say "what is there now is backed up first", which was true
// of the configuration and silent about the plugins, the undo history and the
// shada.
func locationField(takeover *bool) huh.Field {
	return huh.NewSelect[bool]().
		Title("Where should Chroma Neovim be installed?").
		Options(
			huh.NewOption("Beside your own — ~/.config/chroma-nvim, run with NVIM_APPNAME=chroma-nvim", false),
			huh.NewOption("Take over Neovim — ~/.config/nvim, with config, data, state and cache given back on uninstall", true),
		).
		Value(takeover)
}

// componentsField is the selector both `install` and `components` show.
//
// Core is not in the list. It is not a choice, and offering a checkbox that
// cannot be cleared is a worse lie than not offering one.
func componentsField(set component.Set, optional []string, selected *[]string) huh.Field {
	return huh.NewMultiSelect[string]().
		Title("Which parts do you want?").
		Description("Core is always installed and is not listed.").
		Options(componentOptions(set, optional, seeded(*selected))...).
		Value(selected)
}

// componentOptions is what the selector puts in front of somebody.
//
// Split out so a test can read it. The alternative was reaching into huh's
// unexported fields to find out what a built field offers, which would have
// been a test that breaks the next time the library is updated for reasons that
// have nothing to do with Chroma.
func componentOptions(set component.Set, optional []string, already map[string]bool) []huh.Option[string] {
	options := make([]huh.Option[string], 0, len(optional))
	for _, id := range optional {
		label := name(set, id)
		if description := set[id].Description; description != "" {
			label += " — " + description
		}
		options = append(options, huh.NewOption(label, id).Selected(already[id]))
	}
	return options
}

// translate turns the library's errors into this package's two.
//
// A closed pipe has to stay distinguishable from a person pressing escape: the
// first means there was nobody to ask and is misuse, the second is a decision
// and is not.
func translate(err error) error {
	switch {
	case errors.Is(err, huh.ErrUserAborted):
		return ErrAborted
	case errors.Is(err, io.EOF), errors.Is(err, io.ErrUnexpectedEOF):
		return ErrNoInput
	case strings.Contains(err.Error(), "EOF"):
		return ErrNoInput
	default:
		return err
	}
}
