package component

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
)

// **Point 13.** A contract is a file somebody can write by hand, so every value
// in it is an input. A version that is punctuation and nothing else made the
// parser index the first element of an empty slice.
func TestAVersionThatIsOnlyPunctuationIsRefusedRatherThanFatal(t *testing.T) {
	for _, version := range []string{"-", "+", "v-", "v+", "-rc1", "+meta", "v", "..", "v.."} {
		t.Run(version, func(t *testing.T) {
			dir := t.TempDir()
			contract := fmt.Sprintf(`{
  "contract": 5,
  "id": "core",
  "name": "Core",
  "description": "The editor itself.",
  "requires": [],
  "tools": {
    "required": [
      {"id": "git", "reason": "cloning plugins", "version": {"min": %q}}
    ]
  }
}`, version)
			if err := os.WriteFile(filepath.Join(dir, "core.json"), []byte(contract), 0o644); err != nil {
				t.Fatal(err)
			}

			// A panic here fails the test by crashing it, which is the point:
			// nothing about a hand-written file should be able to do that.
			_, problems, err := Load(dir)

			if err == nil && len(problems) == 0 {
				t.Errorf("a minimum version of %q was accepted", version)
			}
		})
	}
}
