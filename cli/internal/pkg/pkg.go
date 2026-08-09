// Package pkg knows how to name and install a tool on a particular system.
//
// The component contract says *what* a component needs — `rg`, `terraform`,
// `ansible-vault`. What that is called in a distribution's repositories, and
// which command installs it, is knowledge about distributions rather than about
// Chroma, so it lives here for the same reason `toolver` holds "how to ask this
// executable its version": a contract that carried package names would carry
// five sets of them, and would be wrong about four.
package pkg

import "fmt"

// Managers are the package managers this knows, in the order they are looked
// for. A machine with two of them is not a machine this should be guessing on,
// so the first found wins and the CLI says which it chose.
var Managers = []string{"pacman", "apt-get", "dnf", "zypper", "brew"}

// packages maps a tool name from the component contract to the package that
// provides it, per manager.
//
// **A name is in here only if it was looked up in that distribution's own
// repository.** Absence is not an oversight and must not be filled in from
// memory: an unknown mapping makes the CLI print an instruction for a human,
// which is a good outcome, while a wrong one makes it run an install that fails
// or — worse — installs something else.
//
// The pacman column was verified against archlinux.org's package search; the
// others are empty until somebody does the same for them.
var packages = map[string]map[string]string{
	"pacman": {
		// core
		"git":         "git",
		"curl":        "curl",
		"tar":         "tar",
		"unzip":       "unzip",
		"gzip":        "gzip",
		"cc":          "gcc",
		"gcc":         "gcc",
		"tree-sitter": "tree-sitter",
		"fzf":         "fzf",
		"rg":          "ripgrep",
		"fd":          "fd",
		"bat":         "bat",
		"yazi":        "yazi",
		"lazygit":     "lazygit",
		// components
		"docker":     "docker",
		"helm":       "helm",
		"kubectl":    "kubectl",
		"terraform":  "terraform",
		"tofu":       "opentofu",
		"terragrunt": "terragrunt",
		"ansible":    "ansible",
		// ansible-vault ships inside ansible-core, and nothing here needs
		// playbooks — which is why the vault component does not require ansible.
		"ansible-vault": "ansible-core",
		"aws":           "aws-cli",
	},
}

// Package returns what to install to get `tool` on this manager.
//
// The second return is the whole point: "I do not know" is an answer, and it is
// the one that leads to an instruction rather than to a command.
func Package(manager, tool string) (string, bool) {
	known, managed := packages[manager]
	if !managed {
		return "", false
	}
	name, found := known[tool]
	return name, found
}

// InstallCommand is the argv that installs these packages.
//
// argv, never a string. Nothing here is handed to a shell, so a package name —
// which arrives from a table in this file, but the principle is what matters —
// cannot become part of a command line. There is no `curl | sh` and there is no
// `sh -c`.
//
// `sudo` is in the command rather than assumed: the user is shown exactly what
// would run, including the fact that it needs root, and agrees to that or does
// not.
func InstallCommand(manager string, names []string) ([]string, bool) {
	if len(names) == 0 {
		return nil, false
	}

	switch manager {
	case "pacman":
		return append([]string{"sudo", "pacman", "-S", "--needed"}, names...), true
	case "apt-get":
		return append([]string{"sudo", "apt-get", "install", "-y"}, names...), true
	case "dnf":
		return append([]string{"sudo", "dnf", "install", "-y"}, names...), true
	case "zypper":
		return append([]string{"sudo", "zypper", "--non-interactive", "install"}, names...), true
	case "brew":
		// No sudo: Homebrew refuses to run as root and says so.
		return append([]string{"brew", "install"}, names...), true
	default:
		return nil, false
	}
}

// Describe renders a command for somebody to read or to type.
func Describe(argv []string) string {
	out := ""
	for i, part := range argv {
		if i > 0 {
			out += " "
		}
		out += part
	}
	return out
}

// ErrUnknownManager is returned when asked about a manager this does not know.
var ErrUnknownManager = fmt.Errorf("unknown package manager")
