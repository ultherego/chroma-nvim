package main

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

// usageText captures what `chroma --help` prints.
func usageText(t *testing.T) string {
	t.Helper()

	read, write, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan string, 1)
	go func() {
		var out strings.Builder
		scanner := bufio.NewScanner(read)
		for scanner.Scan() {
			out.WriteString(scanner.Text())
			out.WriteString("\n")
		}
		done <- out.String()
	}()

	usage(write)
	write.Close()
	return <-done
}

// advertised are the command names the usage text lists, taken from the two
// indented columns it prints them in.
func advertised(t *testing.T) []string {
	t.Helper()

	var names []string
	for _, line := range strings.Split(usageText(t), "\n") {
		if !strings.HasPrefix(line, "  ") || strings.HasPrefix(line, "   ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		// Skip the trailing prose, which is not indented like a command row.
		if strings.Contains(line, "not implemented yet") {
			names = append(names, fields[0])
			continue
		}
		names = append(names, fields[0])
	}
	return names
}

// The gap this exists for: `rollback` was written, built, vetted and unit
// tested, and still reached nobody — the only thing between it and the user was
// a `case` nobody had added, and dispatch as control flow gave no test anything
// to look at. It is a table now, and this is the check.
func TestEveryAdvertisedCommandIsReachable(t *testing.T) {
	names := advertised(t)
	if len(names) < 5 {
		t.Fatalf("the usage text listed %d commands, which cannot be right: %v", len(names), names)
	}

	for _, name := range names {
		if commands[name] != nil {
			continue
		}
		if unfinished[name] {
			continue
		}
		t.Errorf("%q is offered in the usage text and dispatches nowhere", name)
	}
}

// And the other direction: something that dispatches but is never mentioned is
// a command nobody can find.
func TestEveryCommandIsAdvertised(t *testing.T) {
	listed := map[string]bool{}
	for _, name := range advertised(t) {
		listed[name] = true
	}

	for name := range commands {
		if !listed[name] {
			t.Errorf("%q dispatches and is not in the usage text", name)
		}
	}
}

// A command that is not finished must say so rather than being reported as
// unknown, which would read as a typo.
func TestAnUnfinishedCommandSaysSo(t *testing.T) {
	for name := range unfinished {
		if commands[name] != nil {
			t.Errorf("%q is listed as unfinished and also dispatches", name)
		}
	}
}
