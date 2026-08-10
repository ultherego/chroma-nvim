package release

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// serving stands in for the release host, so that failures can be produced on
// purpose rather than waited for. Everything under test is real: the HTTP
// client, the download, the checksum parsing and hashing, and the extractor.
//
// A public GitHub cannot be made to truncate a body or publish a wrong digest,
// and those are exactly the cases that decide whether untrusted input can cross
// the verification boundary.
type serving struct {
	tag    string
	assets map[string][]byte

	// truncate names an asset to send half of, with a Content-Length promising
	// all of it.
	truncate string

	// status is returned for the named asset instead of its contents.
	status map[string]int
}

func (s *serving) start(t *testing.T) string {
	t.Helper()

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/releases/latest") || strings.Contains(r.URL.Path, "/releases/tags/") {
			var assets []string
			for name := range s.assets {
				assets = append(assets, fmt.Sprintf(`{"name":%q,"browser_download_url":"%s/asset/%s"}`,
					name, "http://"+r.Host, name))
			}
			fmt.Fprintf(w, `{"tag_name":%q,"assets":[%s]}`, s.tag, strings.Join(assets, ","))
			return
		}

		name := filepath.Base(r.URL.Path)
		if code, refused := s.status[name]; refused {
			w.WriteHeader(code)
			return
		}

		body, known := s.assets[name]
		if !known {
			w.WriteHeader(http.StatusNotFound)
			return
		}

		if name == s.truncate {
			w.Header().Set("Content-Length", fmt.Sprint(len(body)))
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write(body[:len(body)/2])
			// Closing without the rest is what a dropped connection looks like.
			if flusher, ok := w.(http.Flusher); ok {
				flusher.Flush()
			}
			panic(http.ErrAbortHandler)
		}

		_, _ = w.Write(body)
	}))
	t.Cleanup(server.Close)

	return server.URL
}

// release builds a genuine archive and its checksums, which each case then
// spoils in one specific way.
func release(t *testing.T, tag string) (archive []byte, sums []byte) {
	t.Helper()

	out := t.TempDir()
	result, err := Package(tree(t), tag, out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}

	archive, err = os.ReadFile(result.Archive)
	if err != nil {
		t.Fatal(err)
	}
	sums, err = os.ReadFile(result.Sums)
	if err != nil {
		t.Fatal(err)
	}
	return archive, sums
}

func attempt(t *testing.T, host, tag string) error {
	t.Helper()

	source := GitHubSource{Version: tag, API: host}
	prepared, err := source.Prepare(context.Background())
	if err == nil {
		if prepared.Cleanup != nil {
			_ = prepared.Cleanup()
		}
		t.Fatal("the release was accepted")
	}
	return err
}

func TestADownloadCutInHalfIsRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, sums := release(t, tag)

	host := (&serving{
		tag:      tag,
		assets:   map[string][]byte{ArchiveName(tag): archive, SumsName: sums},
		truncate: ArchiveName(tag),
	}).start(t)

	t.Logf("refused with: %v", attempt(t, host, tag))
}

func TestAnAssetTheHostWillNotServeIsRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, sums := release(t, tag)

	host := (&serving{
		tag:    tag,
		assets: map[string][]byte{ArchiveName(tag): archive, SumsName: sums},
		status: map[string]int{ArchiveName(tag): http.StatusInternalServerError},
	}).start(t)

	t.Logf("refused with: %v", attempt(t, host, tag))
}

// The release does not publish the archive at all. Nothing similar is accepted
// in its place.
func TestAReleaseWithoutTheArchiveIsRefused(t *testing.T) {
	tag := "v9.9.9"
	_, sums := release(t, tag)

	host := (&serving{
		tag: tag,
		assets: map[string][]byte{
			SumsName:                            sums,
			"chroma-nvim-something-else.tar.gz": []byte("not it"),
		},
	}).start(t)

	err := attempt(t, host, tag)
	if !strings.Contains(err.Error(), ArchiveName(tag)) {
		t.Errorf("the refusal does not name what was missing: %v", err)
	}
}

func TestAnArchiveThatDoesNotMatchItsChecksumIsRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, sums := release(t, tag)

	tampered := append([]byte(nil), archive...)
	tampered[len(tampered)-1] ^= 0xff

	host := (&serving{
		tag:    tag,
		assets: map[string][]byte{ArchiveName(tag): tampered, SumsName: sums},
	}).start(t)

	err := attempt(t, host, tag)
	for _, want := range []string{"checksum", "expected", "got"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal does not mention %q: %v", want, err)
		}
	}
}

func TestChecksumsThatDoNotListTheArchiveAreRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, _ := release(t, tag)

	other := sha256.Sum256([]byte("something else"))
	sums := []byte(hex.EncodeToString(other[:]) + "  chroma-linux-amd64\n")

	host := (&serving{
		tag:    tag,
		assets: map[string][]byte{ArchiveName(tag): archive, SumsName: sums},
	}).start(t)

	err := attempt(t, host, tag)
	if !strings.Contains(err.Error(), "does not list") {
		t.Errorf("the refusal does not say the archive is unlisted: %v", err)
	}
}

func TestMalformedChecksumsAreRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, _ := release(t, tag)
	good := sha256.Sum256(archive)
	digest := hex.EncodeToString(good[:])

	for _, tc := range []struct{ name, sums string }{
		{"a digest of the wrong length", digest[:40] + "  " + ArchiveName(tag) + "\n"},
		{"a digest that is not hex", strings.Repeat("z", 64) + "  " + ArchiveName(tag) + "\n"},
		{
			// Both orders. A parser that takes the last entry refuses one and
			// accepts the other, which makes the decision depend on how the
			// file happens to be written rather than on what it says.
			"the same asset twice, the honest digest first",
			digest + "  " + ArchiveName(tag) + "\n" +
				strings.Repeat("a", 64) + "  " + ArchiveName(tag) + "\n",
		},
		{
			"the same asset twice, the honest digest last",
			strings.Repeat("a", 64) + "  " + ArchiveName(tag) + "\n" +
				digest + "  " + ArchiveName(tag) + "\n",
		},
		{
			// Even agreeing with itself, a file that says a thing twice is not
			// a file that says it once.
			"the same asset twice with the same digest",
			digest + "  " + ArchiveName(tag) + "\n" +
				digest + "  " + ArchiveName(tag) + "\n",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			host := (&serving{
				tag:    tag,
				assets: map[string][]byte{ArchiveName(tag): archive, SumsName: []byte(tc.sums)},
			}).start(t)

			t.Logf("refused with: %v", attempt(t, host, tag))
		})
	}
}

// The archive is broken but its checksum is honest, so the failure has to come
// from the extractor rather than from the digest. Otherwise this would only be
// testing the checksum a second time.
func TestABrokenArchiveWithAnHonestChecksumIsRefused(t *testing.T) {
	tag := "v9.9.9"
	archive, _ := release(t, tag)

	broken := archive[:len(archive)/2]
	digest := sha256.Sum256(broken)
	sums := []byte(hex.EncodeToString(digest[:]) + "  " + ArchiveName(tag) + "\n")

	host := (&serving{
		tag:    tag,
		assets: map[string][]byte{ArchiveName(tag): broken, SumsName: sums},
	}).start(t)

	err := attempt(t, host, tag)
	if strings.Contains(err.Error(), "checksum") {
		t.Errorf("this failed at the checksum, so the extractor was never reached: %v", err)
	}
	t.Logf("refused with: %v", err)
}

// The extractor's rules are tested directly elsewhere. This proves they are
// reached from the public path — a release somebody could actually publish,
// prepared the way `install` and `update` prepare one.
//
// The lesson is M7's: a guard that is correct and unreachable protects nothing.
func TestAHostileArchiveIsRefusedThroughTheReleasePath(t *testing.T) {
	tag := "v9.9.9"

	for _, tc := range []struct {
		name  string
		build func(*tar.Writer)
	}{
		{"a path climbing out of the prefix", func(w *tar.Writer) {
			body := []byte("owned\n")
			_ = w.WriteHeader(&tar.Header{Name: Prefix(tag) + "/../../escaped.lua", Mode: 0o644, Size: int64(len(body))})
			_, _ = w.Write(body)
		}},
		{"an absolute path", func(w *tar.Writer) {
			body := []byte("owned\n")
			_ = w.WriteHeader(&tar.Header{Name: "/etc/chroma-owned", Mode: 0o644, Size: int64(len(body))})
			_, _ = w.Write(body)
		}},
		{"a symlink", func(w *tar.Writer) {
			_ = w.WriteHeader(&tar.Header{
				Typeflag: tar.TypeSymlink, Name: Prefix(tag) + "/init.lua",
				Linkname: "/etc/passwd", Mode: 0o777,
			})
		}},
		{"an entry outside the prefix it claims", func(w *tar.Writer) {
			body := []byte("owned\n")
			_ = w.WriteHeader(&tar.Header{Name: "somewhere-else/init.lua", Mode: 0o644, Size: int64(len(body))})
			_, _ = w.Write(body)
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var raw bytes.Buffer
			compressed := gzip.NewWriter(&raw)
			archive := tar.NewWriter(compressed)
			tc.build(archive)
			if err := archive.Close(); err != nil {
				t.Fatal(err)
			}
			if err := compressed.Close(); err != nil {
				t.Fatal(err)
			}

			body := raw.Bytes()
			digest := sha256.Sum256(body)
			sums := []byte(hex.EncodeToString(digest[:]) + "  " + ArchiveName(tag) + "\n")

			host := (&serving{
				tag:    tag,
				assets: map[string][]byte{ArchiveName(tag): body, SumsName: sums},
			}).start(t)

			err := attempt(t, host, tag)
			if strings.Contains(err.Error(), "checksum") {
				t.Fatalf("this failed at the checksum, so the extractor was never reached: %v", err)
			}
			t.Logf("refused with: %v", err)

			if exists("/etc/chroma-owned") {
				t.Fatal("a file was written outside the unpacking directory")
			}
		})
	}
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}
