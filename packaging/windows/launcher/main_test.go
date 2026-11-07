//go:build windows

package main

import (
	"bufio"
	"io"
	"os"
	"path/filepath"
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

func TestPasswordPolicy(t *testing.T) {
	cases := map[string]bool{
		"short-pass1":               false, // 11 characters
		"long-enough!":              true,  // 12 characters
		strings.Repeat("a", 120):    true,
		strings.Repeat("a", 121):    false,
		strings.Repeat(" ", 15):     false,
		strings.Repeat("😀", 6):      true, // 12 UTF-16 code units, as the server counts
		strings.Repeat("😀", 5) + "a": false,
	}
	for password, want := range cases {
		if got := validPassword(password); got != want {
			t.Errorf("validPassword(%q) = %v, want %v", password, got, want)
		}
	}
}

func TestPasswordPromptFromRedirectedInput(t *testing.T) {
	input := bufio.NewReader(strings.NewReader("too-short\ntoo-short\nfirst-password-1\nother-password-1\nchosen-password\nchosen-password\n"))
	stdout := os.Stdout
	reader, writer, _ := os.Pipe()
	os.Stdout = writer
	password, err := askNewPassword(input, false)
	writer.Close()
	os.Stdout = stdout
	output, _ := io.ReadAll(reader)
	if err != nil || password != "chosen-password" {
		t.Fatalf("got %q, %v", password, err)
	}
	if strings.Contains(string(output), "chosen-password") {
		t.Fatal("the password was printed")
	}
	if _, err := askNewPassword(bufio.NewReader(strings.NewReader("")), false); err == nil {
		t.Fatal("empty input must not create a workspace")
	}
}
