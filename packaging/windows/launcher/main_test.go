//go:build windows

package main

import (
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

// These run on real Windows, but the "missing" and "outdated" runtime cases are simulated with
// folders of copied files: the CI machine itself has a current Visual C++ runtime.

func copyFile(t *testing.T, from, to string) {
	t.Helper()
	data, err := os.ReadFile(from)
	if err != nil {
		t.Skipf("cannot read %s: %v", from, err)
	}
	if err := os.WriteFile(to, data, 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestVisualCppMissing(t *testing.T) {
	problem := checkVisualCpp(t.TempDir())
	if problem != "vcruntime140.dll is not installed." {
		t.Fatalf("unexpected result %q", problem)
	}
}

func TestVisualCppOutdated(t *testing.T) {
	folder := t.TempDir()
	system := systemDirectory()
	// kernel32.dll carries a Windows version (10.x), which is older than 14.40.
	copyFile(t, filepath.Join(system, "kernel32.dll"), filepath.Join(folder, "vcruntime140.dll"))
	problem := checkVisualCpp(folder)
	if !strings.HasPrefix(problem, "vcruntime140.dll is version 10.") || !strings.Contains(problem, "14.40.33810.0 or newer") {
		t.Fatalf("unexpected result %q", problem)
	}
}

func TestVisualCppCurrent(t *testing.T) {
	folder := t.TempDir()
	for _, name := range visualCppFiles {
		copyFile(t, filepath.Join(systemDirectory(), name), filepath.Join(folder, name))
	}
	if problem := checkVisualCpp(folder); problem != "" {
		t.Fatalf("a current runtime was rejected: %q", problem)
	}
	if problem := checkVisualCpp(systemDirectory()); problem != "" {
		t.Fatalf("this machine's runtime was rejected: %q", problem)
	}
}

func TestVersionOrder(t *testing.T) {
	if !(fileVersion{14, 38, 0, 0}).less(minimumRuntime) || (fileVersion{14, 40, 33810, 0}).less(minimumRuntime) ||
		(fileVersion{14, 51, 1, 0}).less(minimumRuntime) {
		t.Fatal("version comparison is wrong")
	}
}

func TestSetupTokenMatchesTheServerRule(t *testing.T) {
	// The server accepts a launcher token only if it is 32-128 URL-safe characters.
	rule := regexp.MustCompile(`^[A-Za-z0-9_-]{32,128}$`)
	seen := map[string]bool{}
	for i := 0; i < 20; i++ {
		token, err := newSetupToken()
		if err != nil || !rule.MatchString(token) || seen[token] {
			t.Fatalf("bad token %q (%v)", token, err)
		}
		seen[token] = true
	}
}

func TestBrowserURL(t *testing.T) {
	if got := browserURL(true, "abc"); got != "http://127.0.0.1:8080/#setup=abc" {
		t.Fatalf("setup URL %q", got)
	}
	if got := browserURL(false, "abc"); got != "http://127.0.0.1:8080/" || strings.Contains(got, "abc") {
		t.Fatalf("returning users must get the plain address, got %q", got)
	}
}

func TestLastLinesKeepsTheEndOfJavaOutput(t *testing.T) {
	tail := &lastLines{limit: 2}
	tail.Write([]byte("one\r\n\ntwo\nthr"))
	tail.Write([]byte("ee\nfour"))
	// The last two complete lines are kept, plus the unfinished one.
	if got := tail.String(); got != "two\nthree\nfour" {
		t.Fatalf("unexpected tail %q", got)
	}
}

func TestTestOutputReplacesDialogsAndBrowser(t *testing.T) {
	folder := t.TempDir()
	t.Setenv("OFFICEFLOW_TEST_OUTPUT", folder)
	if code := failure("OfficeFlow could not start.", "line one\nline two"); code != 1 {
		t.Fatalf("failure returned %d", code)
	}
	openBrowser("http://127.0.0.1:8080/#setup=x")
	notify("OfficeFlow has stopped.")
	for name, want := range map[string]string{
		"error.txt":      "OfficeFlow could not start. |  | line one | line two",
		"opened-url.txt": "http://127.0.0.1:8080/#setup=x",
		"notice.txt":     "OfficeFlow has stopped.",
	} {
		data, err := os.ReadFile(filepath.Join(folder, name))
		if err != nil || strings.TrimSpace(string(data)) != want {
			t.Fatalf("%s: %q (%v)", name, data, err)
		}
	}
}

func TestPortFree(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	address := listener.Addr().String()
	if portFree(address) {
		t.Fatal("a port in use was reported free")
	}
	listener.Close()
	if !portFree(address) {
		t.Fatal("a released port was reported busy")
	}
}
