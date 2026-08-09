package release

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// crafted builds an archive by hand, which is the only way to write the ones a
// release would never contain.
func crafted(t *testing.T, entries []*tar.Header, bodies []string) []byte {
	t.Helper()

	var buffer bytes.Buffer
	compressed := gzip.NewWriter(&buffer)
	archive := tar.NewWriter(compressed)

	for i, header := range entries {
		if err := archive.WriteHeader(header); err != nil {
			t.Fatalf("writing header %d: %v", i, err)
		}
		if i < len(bodies) && bodies[i] != "" {
			if _, err := archive.Write([]byte(bodies[i])); err != nil {
				t.Fatalf("writing body %d: %v", i, err)
			}
		}
	}

	if err := archive.Close(); err != nil {
		t.Fatalf("closing the archive: %v", err)
	}
	if err := compressed.Close(); err != nil {
		t.Fatalf("closing the compressor: %v", err)
	}
	return buffer.Bytes()
}

func file(name string, size int64) *tar.Header {
	return &tar.Header{Typeflag: tar.TypeReg, Name: name, Size: size, Mode: 0o644}
}

// A real archive round-trips, or every refusal below would be a refusal of
// everything.
func TestExtractUnpacksARealArchive(t *testing.T) {
	out := t.TempDir()
	result, err := Package(tree(t), "v1.0.0", out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	contents, err := os.ReadFile(result.Archive)
	if err != nil {
		t.Fatalf("reading the archive: %v", err)
	}

	into := t.TempDir()
	if err := Extract(bytes.NewReader(contents), into, Prefix("v1.0.0")); err != nil {
		t.Fatalf("Extract: %v", err)
	}

	// The prefix is stripped: what lands is a configuration directory, not a
	// directory containing one.
	for _, wanted := range []string{"init.lua", "lua/chroma/state.lua", "components/core.json", "doc/chroma-nvim.txt"} {
		if _, err := os.Stat(filepath.Join(into, filepath.FromSlash(wanted))); err != nil {
			t.Errorf("%s did not arrive: %v", wanted, err)
		}
	}
	if _, err := os.Stat(filepath.Join(into, "chroma-nvim-v1.0.0")); err == nil {
		t.Error("the prefix directory was created rather than stripped")
	}
}

// The archive is somebody else's, and every one of these is a way of writing
// outside the directory it was told to write into.
func TestExtractRefusesAnArchiveThatWouldEscape(t *testing.T) {
	prefix := Prefix("v1.0.0")

	for _, tc := range []struct {
		name    string
		headers []*tar.Header
		mention string
	}{
		{
			name:    "an absolute path",
			headers: []*tar.Header{file("/etc/passwd", 0)},
			mention: "not a plain relative path",
		},
		{
			name:    "a path that climbs out",
			headers: []*tar.Header{file("../../etc/passwd", 0)},
			mention: "not a plain relative path",
		},
		{
			name:    "a path that climbs out from inside the prefix",
			headers: []*tar.Header{file(prefix+"/../../etc/passwd", 0)},
			mention: "not a plain relative path",
		},
		{
			name:    "an entry outside the prefix it claims",
			headers: []*tar.Header{file("somewhere-else/init.lua", 0)},
			mention: "is not under",
		},
		{
			name:    "a symlink",
			headers: []*tar.Header{{Typeflag: tar.TypeSymlink, Name: prefix + "/init.lua", Linkname: "/etc/passwd", Mode: 0o777}},
			mention: "neither a file nor a directory",
		},
		{
			name:    "a hardlink",
			headers: []*tar.Header{{Typeflag: tar.TypeLink, Name: prefix + "/init.lua", Linkname: "/etc/passwd", Mode: 0o644}},
			mention: "neither a file nor a directory",
		},
		{
			name:    "a device",
			headers: []*tar.Header{{Typeflag: tar.TypeChar, Name: prefix + "/init.lua", Mode: 0o666}},
			mention: "neither a file nor a directory",
		},
		{
			name:    "a fifo",
			headers: []*tar.Header{{Typeflag: tar.TypeFifo, Name: prefix + "/init.lua", Mode: 0o666}},
			mention: "neither a file nor a directory",
		},
		{
			name:    "nothing under the prefix at all",
			headers: []*tar.Header{{Typeflag: tar.TypeDir, Name: prefix + "/", Mode: 0o755}},
			mention: "contains no files",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			into := t.TempDir()

			err := Extract(bytes.NewReader(crafted(t, tc.headers, nil)), into, prefix)
			if err == nil {
				t.Fatal("unpacked an archive that should have been refused")
			}
			if !strings.Contains(err.Error(), tc.mention) {
				t.Errorf("err = %v, want it to mention %q", err, tc.mention)
			}

			// And nothing arrived anywhere.
			entries, readErr := os.ReadDir(into)
			if readErr != nil {
				t.Fatalf("reading %s: %v", into, readErr)
			}
			for _, entry := range entries {
				if entry.Name() != "" {
					t.Errorf("%s was created by a refused archive", entry.Name())
				}
			}
		})
	}
}

// A header's size is the archive's claim about itself, not a fact, so it is
// bounded on the way in and again while copying.
func TestExtractRefusesAnEntryTooLargeToBeConfiguration(t *testing.T) {
	prefix := Prefix("v1.0.0")
	into := t.TempDir()

	saved := maxEntrySize
	maxEntrySize = 16
	t.Cleanup(func() { maxEntrySize = saved })

	body := strings.Repeat("x", 64)
	err := Extract(
		bytes.NewReader(crafted(t, []*tar.Header{file(prefix+"/init.lua", int64(len(body)))}, []string{body})),
		into, prefix,
	)
	if err == nil {
		t.Fatal("unpacked an entry larger than the limit")
	}
	if !strings.Contains(err.Error(), "any business being") {
		t.Errorf("err = %v", err)
	}
}

func TestExtractRefusesSomethingThatIsNotAnArchive(t *testing.T) {
	if err := Extract(strings.NewReader("this is not a gzip"), t.TempDir(), "chroma-nvim-v1.0.0"); err == nil {
		t.Error("accepted something that is not an archive")
	}
}
