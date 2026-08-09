package release

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// releaseServer stands in for GitHub, serving a release built by the packager.
// No network, and the archive is a real one — the checksum, the prefix and the
// contract are all the packager's own output rather than a fixture that agrees
// with it by hand.
type releaseServer struct {
	*httptest.Server

	tag     string
	archive []byte
	sums    []byte

	// Faults a test can ask for.
	corruptArchive bool
	omitSums       bool
	rateLimited    bool
	missing        bool
}

func serve(t *testing.T, tag string) *releaseServer {
	t.Helper()

	out := t.TempDir()
	result, err := Package(tree(t), tag, out)
	if err != nil {
		t.Fatalf("Package: %v", err)
	}
	archive, err := os.ReadFile(result.Archive)
	if err != nil {
		t.Fatalf("reading the archive: %v", err)
	}
	sums, err := os.ReadFile(result.Sums)
	if err != nil {
		t.Fatalf("reading the sums: %v", err)
	}

	server := &releaseServer{tag: tag, archive: archive, sums: sums}
	server.Server = httptest.NewServer(http.HandlerFunc(server.handle))
	t.Cleanup(server.Close)
	return server
}

func (s *releaseServer) handle(w http.ResponseWriter, r *http.Request) {
	if s.rateLimited {
		w.Header().Set("X-RateLimit-Remaining", "0")
		w.Header().Set("X-RateLimit-Reset", "1786300000")
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if s.missing {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	switch {
	case strings.Contains(r.URL.Path, "/releases/latest"), strings.Contains(r.URL.Path, "/releases/tags/"):
		assets := fmt.Sprintf(`{"name": %q, "browser_download_url": "%s/download/archive"}`,
			ArchiveName(s.tag), s.URL)
		if !s.omitSums {
			assets += fmt.Sprintf(`, {"name": %q, "browser_download_url": "%s/download/sums"}`, SumsName, s.URL)
		}
		fmt.Fprintf(w, `{"tag_name": %q, "assets": [%s]}`, s.tag, assets)

	case r.URL.Path == "/download/archive":
		body := s.archive
		if s.corruptArchive {
			body = append(append([]byte{}, s.archive...), "tampered"...)
		}
		w.Write(body)

	case r.URL.Path == "/download/sums":
		w.Write(s.sums)

	default:
		w.WriteHeader(http.StatusNotFound)
	}
}

func TestAReleaseIsFetchedVerifiedAndUnpacked(t *testing.T) {
	server := serve(t, "v1.0.0")

	source := GitHubSource{Version: "v1.0.0", API: server.URL, Client: server.Client()}
	prepared, err := source.Prepare(context.Background())
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	t.Cleanup(func() { _ = prepared.Cleanup() })

	if prepared.Kind != install.KindRelease {
		t.Errorf("kind = %q, want a release", prepared.Kind)
	}
	if prepared.Version != "v1.0.0" {
		t.Errorf("version = %q", prepared.Version)
	}
	if prepared.SHA256 == "" {
		t.Error("nothing recorded the checksum that was verified")
	}
	// Unpacked with the prefix stripped, so what was prepared is a
	// configuration directory — the same shape a checkout hands over.
	if _, err := os.Stat(filepath.Join(prepared.Root, "init.lua")); err != nil {
		t.Errorf("the prepared source has no init.lua: %v", err)
	}
	if _, err := os.Stat(filepath.Join(prepared.Root, "components", "core.json")); err != nil {
		t.Errorf("the prepared source has no contract: %v", err)
	}

	if err := prepared.Cleanup(); err != nil {
		t.Errorf("Cleanup: %v", err)
	}
	if _, err := os.Stat(prepared.Root); !os.IsNotExist(err) {
		t.Error("cleanup left the unpacked release behind")
	}
}

// `latest` is resolved to a tag before anything else happens, so the plan names
// a version somebody can check and the install state records one.
func TestLatestResolvesToATag(t *testing.T) {
	server := serve(t, "v2.3.4")

	source := GitHubSource{Version: Latest, API: server.URL, Client: server.Client()}
	prepared, err := source.Prepare(context.Background())
	if err != nil {
		t.Fatalf("Prepare: %v", err)
	}
	t.Cleanup(func() { _ = prepared.Cleanup() })

	if prepared.Version != "v2.3.4" {
		t.Errorf("version = %q, want the tag latest resolved to", prepared.Version)
	}
}

// The whole point of publishing checksums: an archive that does not match is
// not unpacked, and nothing of the user's has been touched by the time it is
// refused.
func TestATamperedArchiveIsRefusedBeforeItIsUnpacked(t *testing.T) {
	server := serve(t, "v1.0.0")
	server.corruptArchive = true

	source := GitHubSource{Version: "v1.0.0", API: server.URL, Client: server.Client()}
	_, err := source.Prepare(context.Background())
	if err == nil {
		t.Fatal("unpacked an archive whose checksum did not match")
	}
	for _, wanted := range []string{"does not match the checksum", "Nothing was unpacked"} {
		if !strings.Contains(err.Error(), wanted) {
			t.Errorf("err = %v, want it to say %q", err, wanted)
		}
	}
}

func TestAReleaseWithoutChecksumsIsRefused(t *testing.T) {
	server := serve(t, "v1.0.0")
	server.omitSums = true

	source := GitHubSource{Version: "v1.0.0", API: server.URL, Client: server.Client()}
	_, err := source.Prepare(context.Background())
	if err == nil {
		t.Fatal("installed a release that published no checksums")
	}
	if !strings.Contains(err.Error(), SumsName) {
		t.Errorf("err = %v, want it to name what was missing", err)
	}
}

func TestAReleaseThatIsNotThereSaysSo(t *testing.T) {
	server := serve(t, "v1.0.0")
	server.missing = true

	source := GitHubSource{Version: "v9.9.9", API: server.URL, Client: server.Client()}
	_, err := source.Prepare(context.Background())
	if err == nil {
		t.Fatal("prepared a release that does not exist")
	}
	if !strings.Contains(err.Error(), "no such release") {
		t.Errorf("err = %v", err)
	}
}

// The failure a user behind shared egress meets. A bare 403 tells them nothing
// about what to do next.
func TestRateLimitingIsExplained(t *testing.T) {
	server := serve(t, "v1.0.0")
	server.rateLimited = true

	source := GitHubSource{Version: "v1.0.0", API: server.URL, Client: server.Client()}
	_, err := source.Prepare(context.Background())
	if err == nil {
		t.Fatal("carried on through a rate limit")
	}
	for _, wanted := range []string{"rate-limiting", "GITHUB_TOKEN"} {
		if !strings.Contains(err.Error(), wanted) {
			t.Errorf("err = %v, want it to say %q", err, wanted)
		}
	}
}

// A cancelled installation stops at the network rather than carrying on.
func TestPrepareRespectsCancellation(t *testing.T) {
	server := serve(t, "v1.0.0")

	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	source := GitHubSource{Version: "v1.0.0", API: server.URL, Client: server.Client()}
	if _, err := source.Prepare(ctx); err == nil {
		t.Error("prepared a release from a cancelled context")
	}
}
