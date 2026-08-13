package report

import (
	"fmt"
	"io"

	"charm.land/lipgloss/v2"
	"github.com/charmbracelet/x/ansi"
)

// The wordmark from the README, in the two colours the image is drawn in:
// Chroma in mauve, Neovim in peach. Half-block letters rather than an image,
// because a terminal that can show a PNG is a terminal — this is the same
// twenty-five columns in Kitty, in a pipe, and in a log read a month later.
const (
	chroma = "█▀▀ █ █ █▀▄ █▀█ █▀▄▀█ ▄▀█\n" +
		"█   █▀█ █▀▄ █ █ █ ▀ █ █▀█\n" +
		"▀▀▀ ▀ ▀ ▀ ▀ ▀▀▀ ▀   ▀ ▀ ▀"

	neovim = "█▄ █ █▀▀ █▀█ █ █ █ █▀▄▀█\n" +
		"█ ▀█ █▀▀ █ █ ▀▄▀ █ █ ▀ █\n" +
		"▀  ▀ ▀▀▀ ▀▀▀  ▀  ▀ ▀   ▀"
)

// Clear wipes the screen a command is about to draw on, and only where there is
// one to wipe: an escape sequence in a log file is noise, and a CLI that clears
// a pipe is one whose output nothing will see it happen to.
//
// The scrollback survives. `ansi.EraseEntireDisplay` would throw away what
// somebody had on screen before they ran this.
func Clear(w io.Writer) {
	if room(w) <= 0 {
		return
	}
	fmt.Fprint(w, ansi.EraseEntireScreen+ansi.CursorHomePosition)
}

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
