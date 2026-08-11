package report

import (
	"fmt"
	"io"

	"charm.land/lipgloss/v2"
)

// The wordmark from the README, in the two colours the image is drawn in:
// Chroma in mauve, Neovim in peach.
//
// Half-block letters rather than an image. The logo in the README is a PNG, and
// a terminal that can show one is a terminal — which would make the top of
// `chroma install` mean different things depending on where it ran. This is
// twenty-five columns of text: the same in Kitty, in a pipe, and in a log
// somebody reads a month later.
const (
	chroma = "█▀▀ █ █ █▀▄ █▀█ █▀▄▀█ ▄▀█\n" +
		"█   █▀█ █▀▄ █ █ █ ▀ █ █▀█\n" +
		"▀▀▀ ▀ ▀ ▀ ▀ ▀▀▀ ▀   ▀ ▀ ▀"

	neovim = "█▄ █ █▀▀ █▀█ █ █ █ █▀▄▀█\n" +
		"█ ▀█ █▀▀ █ █ ▀▄▀ █ █ ▀ █\n" +
		"▀  ▀ ▀▀▀ ▀▀▀  ▀  ▀ ▀   ▀"
)

// Banner prints the wordmark above whatever a command is about to say.
//
// A terminal too narrow to hold it gets the name on one line instead. Drawing
// it anyway would wrap the letters into each other, and a wordmark nobody can
// read is worse than a word.
func Banner(w io.Writer) {
	width := room(w)
	out := colour(w)

	if width > 0 && width < lipgloss.Width(chroma) {
		fmt.Fprintf(out, "%s %s\n\n",
			lipgloss.NewStyle().Bold(true).Foreground(mauve).Render("Chroma"),
			lipgloss.NewStyle().Bold(true).Foreground(peach).Render("Neovim"))
		return
	}

	fmt.Fprintf(out, "%s\n%s\n\n",
		lipgloss.NewStyle().Foreground(mauve).Render(chroma),
		lipgloss.NewStyle().Foreground(peach).Render(neovim))
}
