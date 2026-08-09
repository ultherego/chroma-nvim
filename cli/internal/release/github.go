package release

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/ultherego/chroma-nvim/cli/internal/component"
	"github.com/ultherego/chroma-nvim/cli/internal/install"
)

// Where releases come from. Not flags: this installs Chroma Neovim, and a
// `--owner` would make it a general-purpose GitHub installer, which is a
// different and much less safe program.
const (
	Owner = "ultherego"
	Repo  = "chroma-nvim"
)

// Latest asks for whatever the newest release is.
const Latest = "latest"

// GitHubSource fetches a release and prepares it for installation.
//
// It produces the same install.PreparedSource a checkout does, and everything
// downstream is written against that. This is not a second installer; it is a
// second way of getting the bytes.
type GitHubSource struct {
	// Version is a tag, or Latest. Resolved to a tag before anything is shown
	// to the user, because a plan that says "latest" is a plan nobody can check
	// and an install state that recorded it would describe nothing.
	Version string

	// API is where the release metadata comes from. Empty means GitHub.
	API string

	// Client is the HTTP client. Empty means one with a timeout.
	Client *http.Client
}

type releaseMetadata struct {
	TagName string `json:"tag_name"`
	Assets  []struct {
		Name string `json:"name"`
		URL  string `json:"browser_download_url"`
	} `json:"assets"`
}

func (s GitHubSource) api() string {
	if s.API != "" {
		return strings.TrimSuffix(s.API, "/")
	}
	return "https://api.github.com"
}

func (s GitHubSource) client() *http.Client {
	if s.Client != nil {
		return s.Client
	}
	// A download of a few hundred kilobytes over a connection that may be slow;
	// generous, and not unbounded.
	return &http.Client{Timeout: 5 * time.Minute}
}

// Prepare resolves the release, verifies it and unpacks it.
//
// The order is the one thing here that is not negotiable:
//
//	resolve  →  download sums  →  download archive  →  compare  →  extract
//
// Nothing is unpacked before its checksum has been compared, and nothing about
// the machine's own configuration is touched at any point in this function. A
// release that fails any of these steps leaves a temporary directory to delete
// and nothing else.
func (s GitHubSource) Prepare(ctx context.Context) (install.PreparedSource, error) {
	metadata, err := s.resolve(ctx)
	if err != nil {
		return install.PreparedSource{}, err
	}

	archiveName := ArchiveName(metadata.TagName)
	archiveURL, err := assetURL(metadata, archiveName)
	if err != nil {
		return install.PreparedSource{}, err
	}
	sumsURL, err := assetURL(metadata, SumsName)
	if err != nil {
		return install.PreparedSource{}, err
	}

	sumsBody, err := s.get(ctx, sumsURL)
	if err != nil {
		return install.PreparedSource{}, fmt.Errorf("downloading %s: %w", SumsName, err)
	}
	sums, err := ReadSums(sumsBody)
	if err != nil {
		return install.PreparedSource{}, err
	}
	expected, listed := sums[archiveName]
	if !listed {
		return install.PreparedSource{}, fmt.Errorf("%s of release %s does not list %s", SumsName, metadata.TagName, archiveName)
	}

	archive, err := s.get(ctx, archiveURL)
	if err != nil {
		return install.PreparedSource{}, fmt.Errorf("downloading %s: %w", archiveName, err)
	}

	digest := sha256.Sum256(archive)
	if got := hex.EncodeToString(digest[:]); got != expected {
		return install.PreparedSource{}, fmt.Errorf(
			"%s does not match the checksum published with release %s:\n  expected %s\n  got      %s\nNothing was unpacked and nothing on this machine was touched",
			archiveName, metadata.TagName, expected, got)
	}

	into, err := os.MkdirTemp("", "chroma-release-*")
	if err != nil {
		return install.PreparedSource{}, fmt.Errorf("creating a directory to unpack into: %w", err)
	}
	cleanup := func() error { return os.RemoveAll(into) }

	if err := Extract(strings.NewReader(string(archive)), into, Prefix(metadata.TagName)); err != nil {
		_ = cleanup()
		return install.PreparedSource{}, err
	}

	// The same reader the editor uses, on what was just unpacked. A release
	// whose contract does not load is refused here, before anything of the
	// user's has been touched.
	set, problems, err := component.Load(filepath.Join(into, "components"))
	if err != nil {
		_ = cleanup()
		return install.PreparedSource{}, fmt.Errorf("reading the component contract of release %s: %w", metadata.TagName, err)
	}
	if len(problems) > 0 {
		_ = cleanup()
		return install.PreparedSource{}, fmt.Errorf("the component contract of release %s does not read: %s", metadata.TagName, strings.Join(problems, "; "))
	}
	if problems := set.ResolveProblems(); len(problems) > 0 {
		_ = cleanup()
		return install.PreparedSource{}, fmt.Errorf("the component contract of release %s does not resolve: %s", metadata.TagName, strings.Join(problems, "; "))
	}

	return install.PreparedSource{
		Root:     into,
		Kind:     install.KindRelease,
		Version:  metadata.TagName,
		Contract: component.Contract,
		SHA256:   expected,
		Cleanup:  cleanup,
	}, nil
}

// resolve turns "latest" into a tag, and checks that a named tag exists.
func (s GitHubSource) resolve(ctx context.Context) (releaseMetadata, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/releases/tags/%s", s.api(), Owner, Repo, s.Version)
	if s.Version == "" || s.Version == Latest {
		url = fmt.Sprintf("%s/repos/%s/%s/releases/latest", s.api(), Owner, Repo)
	}

	body, err := s.get(ctx, url)
	if err != nil {
		return releaseMetadata{}, err
	}

	var metadata releaseMetadata
	if err := json.Unmarshal(body, &metadata); err != nil {
		return releaseMetadata{}, fmt.Errorf("reading the release metadata: %w", err)
	}
	if metadata.TagName == "" {
		return releaseMetadata{}, errors.New("the release metadata names no tag")
	}
	return metadata, nil
}

// assetURL finds one asset by name, and says what was there when it cannot.
func assetURL(metadata releaseMetadata, name string) (string, error) {
	var available []string
	for _, asset := range metadata.Assets {
		if asset.Name == name {
			return asset.URL, nil
		}
		available = append(available, asset.Name)
	}

	if len(available) == 0 {
		return "", fmt.Errorf("release %s has no assets at all, so it is not a release this can install", metadata.TagName)
	}
	return "", fmt.Errorf("release %s has no %s; it has %s", metadata.TagName, name, strings.Join(available, ", "))
}

// get fetches a URL, and turns the failures worth explaining into sentences.
func (s GitHubSource) get(ctx context.Context, url string) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("Accept", "application/vnd.github+json")
	request.Header.Set("User-Agent", "chroma-nvim-installer")

	// Used when it is there, never required. It lifts the rate limit for people
	// who have one — CI, and anybody behind shared egress — and its absence is
	// the ordinary case rather than an error.
	if token := os.Getenv("GITHUB_TOKEN"); token != "" {
		request.Header.Set("Authorization", "Bearer "+token)
	}

	response, err := s.client().Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()

	switch {
	case response.StatusCode == http.StatusNotFound:
		return nil, fmt.Errorf("there is no such release: %s", url)

	case response.StatusCode == http.StatusForbidden && response.Header.Get("X-RateLimit-Remaining") == "0":
		// The failure a user behind shared egress meets, and a bare 403 tells
		// them nothing about what to do next.
		when := "shortly"
		if reset := response.Header.Get("X-RateLimit-Reset"); reset != "" {
			when = "after " + reset + " (unix time)"
		}
		return nil, fmt.Errorf(
			"GitHub is rate-limiting this address; try again %s, or set GITHUB_TOKEN to a token with no scopes to raise the limit", when)

	case response.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("%s returned %s", url, response.Status)
	}

	// Bounded: the response is somebody else's, and the archive this expects is
	// measured in hundreds of kilobytes.
	body, err := io.ReadAll(io.LimitReader(response.Body, maxEntrySize+1))
	if err != nil {
		return nil, err
	}
	if int64(len(body)) > maxEntrySize {
		return nil, fmt.Errorf("%s returned more than %d bytes", url, maxEntrySize)
	}
	return body, nil
}
