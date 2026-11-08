//go:build windows

// OfficeFlow.exe starts installed OfficeFlow without a console window. It checks the Microsoft
// Visual C++ runtime, starts the bundled Java runtime in the background, and opens the browser
// once the server answers: on a new workspace with a one-time setup link, otherwise on sign-in.
// It keeps running, without a window, until OfficeFlow is quit from the browser or with
// "OfficeFlow.exe --quit" (the "Quit OfficeFlow" Start menu shortcut), and shows a message box
// if OfficeFlow cannot start. Its only child process is runtime\bin\java.exe; it never starts
// cmd.exe or PowerShell.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	serverAddress       = "127.0.0.1:8080"
	serverURL           = "http://" + serverAddress + "/"
	redistributablePage = "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist"
	createNoWindow      = 0x08000000 // CREATE_NO_WINDOW: Java gets no console of its own
	startTimeout        = 90 * time.Second
	quitTimeout         = 30 * time.Second
)

func main() {
	os.Exit(run(os.Args[1:]))
}

func run(arguments []string) int {
	if len(arguments) > 0 && arguments[0] == "--quit" {
		return quitRunning()
	}
	if !holdInstanceMutex() {
		// Another OfficeFlow.exe is starting or running: bring up its "window", the browser.
		return openRunning()
	}
	executable, err := os.Executable()
	if err != nil {
		return failure("OfficeFlow could not find its own folder.", err.Error())
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	root := filepath.Dir(executable)
	java := filepath.Join(root, "runtime", "bin", "java.exe")
	jar := filepath.Join(root, "app", "officeflow.jar")
	site := filepath.Join(root, "app", "site")

	if !exists(java) || !exists(jar) || !exists(filepath.Join(site, "index.html")) {
		return failure("Some OfficeFlow files are missing from "+root+".",
			"Run OfficeFlow setup again to repair the installation. Your workspace is not affected.")
	}
	if problem := checkVisualCpp(systemDirectory()); problem != "" {
		openBrowser(redistributablePage)
		return failure("OfficeFlow needs the Microsoft Visual C++ Redistributable (x64), version 14.40 or newer.",
			problem+"\n\nYour browser now shows Microsoft's download page. Choose the X64 file "+
				"(vc_redist.x64.exe), install it, then open OfficeFlow again.")
	}
	if officeFlowAnswers(2 * time.Second) {
		// Started some other way (for example from the ZIP): use that one.
		openBrowser(serverURL)
		return 0
	}
	if !portFree(serverAddress) {
		return failure("Another program is using port 8080 on this computer, so OfficeFlow cannot start.",
			"Close that program, then open OfficeFlow again. Your workspace has not been changed.")
	}

	data := filepath.Join(os.Getenv("LOCALAPPDATA"), "OfficeFlow")
	if err := os.MkdirAll(data, 0o700); err != nil {
		return failure("OfficeFlow could not create its workspace folder "+data+".", err.Error())
	}
	// Java's output, replaced on every start, for support. The workspace log officeflow.log
	// (written by Java) records each start and clean stop.
	logPath := filepath.Join(data, "launcher.log")
	logFile, err := os.Create(logPath)
	if err != nil {
		return failure("OfficeFlow could not write "+logPath+".", err.Error())
	}
	defer logFile.Close()
	tail := &lastLines{limit: 12}
	output := io.MultiWriter(logFile, tail)

	token, err := newSetupToken()
	if err != nil {
		return failure("OfficeFlow could not prepare its setup link.", err.Error())
	}
	command := exec.Command(java, "-Dofficeflow.site="+site, "-Dofficeflow.browserSetup=true",
		"-Dofficeflow.stopWhenInputCloses=true", "-jar", jar)
	command.Dir = root
	// The token is passed only in Java's environment and in the URL fragment the browser opens:
	// never on a command line, in a log, or in a request the browser sends.
	command.Env = append(os.Environ(), "OFFICEFLOW_SETUP_TOKEN="+token)
	command.Stdout = output
	command.Stderr = output
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: createNoWindow, HideWindow: true}
	// Java stops cleanly when its input closes, which also happens if this launcher ends.
	input, err := command.StdinPipe()
	if err != nil {
		return failure("OfficeFlow could not prepare Java.", err.Error())
	}
	if err := command.Start(); err != nil {
		return failure("OfficeFlow could not start its Java runtime.", err.Error())
	}
	defer input.Close()
	exited := make(chan struct{})
	go func() {
		command.Wait()
		close(exited)
	}()

	select {
	case <-exited:
		return failure("OfficeFlow could not start.", startupDetails(tail.String(), logPath))
	case ready := <-waitUntilReady(startTimeout, exited):
		if !ready {
			select {
			case <-exited:
				return failure("OfficeFlow could not start.", startupDetails(tail.String(), logPath))
			default:
			}
			input.Close()
			<-exited
			return failure("OfficeFlow did not start within 90 seconds.", startupDetails(tail.String(), logPath))
		}
	}
	setup, _ := setupRequired()
	openBrowser(browserURL(setup, token))

	<-exited
	if code := command.ProcessState.ExitCode(); code != 0 {
		return failure(fmt.Sprintf("OfficeFlow stopped unexpectedly (exit code %d).", code),
			startupDetails(tail.String(), logPath))
	}
	return 0
}

// browserURL opens the setup screen with the one-time token while the workspace has no
// administrator. The fragment (#...) stays in the browser; it is never sent to the server.
func browserURL(setup bool, token string) string {
	if setup {
		return serverURL + "#setup=" + token
	}
	return serverURL
}

func newSetupToken() (string, error) {
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(secret), nil
}

func startupDetails(output, logPath string) string {
	output = strings.TrimSpace(output)
	if output == "" {
		output = "OfficeFlow ended without a message."
	}
	return output + "\n\nDetails are saved in " + logPath + "\nYour workspace has not been changed."
}

// openRunning waits for an OfficeFlow that is starting, then opens the browser on it.
func openRunning() int {
	deadline := time.Now().Add(startTimeout)
	for time.Now().Before(deadline) {
		if officeFlowAnswers(time.Second) {
			openBrowser(serverURL)
			return 0
		}
		if !instanceRunning() {
			return failure("OfficeFlow stopped while it was opening.", "Open OfficeFlow again.")
		}
		time.Sleep(500 * time.Millisecond)
	}
	return failure("OfficeFlow is taking too long to start.", "Wait a moment, then open OfficeFlow again.")
}

// quitRunning asks OfficeFlow to stop cleanly and waits until it has.
func quitRunning() int {
	if !officeFlowAnswers(2 * time.Second) {
		if instanceRunning() {
			return failure("OfficeFlow is still starting or stopping.", "Try again in a moment.")
		}
		notify("OfficeFlow is not running.")
		return 0
	}
	if err := requestQuit(); err != nil {
		return failure("OfficeFlow could not be asked to quit.", err.Error())
	}
	deadline := time.Now().Add(quitTimeout)
	for time.Now().Before(deadline) {
		if !instanceRunning() && !officeFlowAnswers(time.Second) {
			notify("OfficeFlow has stopped. Your workspace is saved.")
			return 0
		}
		time.Sleep(300 * time.Millisecond)
	}
	return failure("OfficeFlow did not stop within 30 seconds.", "Try again in a moment.")
}

func requestQuit() error {
	client := http.Client{Timeout: 5 * time.Second}
	response, err := client.Post(serverURL+"api/quit", "application/json", strings.NewReader("{}"))
	if err != nil {
		return err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return fmt.Errorf("OfficeFlow answered %s", response.Status)
	}
	return nil
}

func officeFlowAnswers(timeout time.Duration) bool {
	client := http.Client{Timeout: timeout}
	response, err := client.Get(serverURL + "api/health")
	if err != nil {
		return false
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 4096))
	return response.StatusCode == http.StatusOK && strings.Contains(string(body), `"service":"officeflow"`)
}

func setupRequired() (bool, error) {
	client := http.Client{Timeout: 5 * time.Second}
	response, err := client.Get(serverURL + "api/setup")
	if err != nil {
		return false, err
	}
	defer response.Body.Close()
	var status struct {
		Required bool `json:"required"`
	}
	err = json.NewDecoder(io.LimitReader(response.Body, 4096)).Decode(&status)
	return status.Required, err
}

// waitUntilReady reports true once the server answers, false on timeout or if Java exits.
func waitUntilReady(timeout time.Duration, exited <-chan struct{}) <-chan bool {
	result := make(chan bool, 1)
	go func() {
		deadline := time.Now().Add(timeout)
		for time.Now().Before(deadline) {
			select {
			case <-exited:
				result <- false
				return
			case <-time.After(300 * time.Millisecond):
			}
			if officeFlowAnswers(time.Second) {
				result <- true
				return
			}
		}
		result <- false
	}()
	return result
}

func portFree(address string) bool {
	listener, err := net.Listen("tcp", address)
	if err != nil {
		return false
	}
	listener.Close()
	return true
}

func openBrowser(url string) {
	if folder := os.Getenv("OFFICEFLOW_TEST_OUTPUT"); folder != "" {
		record(folder, "opened-url.txt", url)
		return
	}
	if os.Getenv("OFFICEFLOW_NO_BROWSER") != "" {
		return
	}
	shellOpen(url)
}

// failure shows a readable error and returns exit code 1.
func failure(summary, details string) int {
	text := summary
	if details != "" {
		text += "\n\n" + details
	}
	if folder := os.Getenv("OFFICEFLOW_TEST_OUTPUT"); folder != "" {
		record(folder, "error.txt", text)
		return 1
	}
	messageBox(text, true)
	return 1
}

func notify(text string) {
	if folder := os.Getenv("OFFICEFLOW_TEST_OUTPUT"); folder != "" {
		record(folder, "notice.txt", text)
		return
	}
	messageBox(text, false)
}

// record writes a line for automated tests (OFFICEFLOW_TEST_OUTPUT) instead of a dialog or a
// browser window, so a test machine never waits on a message box.
func record(folder, name, text string) {
	file, err := os.OpenFile(filepath.Join(folder, name), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	fmt.Fprintln(file, strings.ReplaceAll(text, "\n", " | "))
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

// lastLines keeps the last few lines Java printed, for the error message.
type lastLines struct {
	mu      sync.Mutex
	limit   int
	partial []byte
	lines   []string
}

func (l *lastLines) Write(data []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	l.partial = append(l.partial, data...)
	for {
		index := bytes.IndexByte(l.partial, '\n')
		if index < 0 {
			break
		}
		line := strings.TrimRight(string(l.partial[:index]), "\r")
		l.partial = l.partial[index+1:]
		if strings.TrimSpace(line) == "" {
			continue
		}
		l.lines = append(l.lines, line)
		if len(l.lines) > l.limit {
			l.lines = l.lines[len(l.lines)-l.limit:]
		}
	}
	return len(data), nil
}

func (l *lastLines) String() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	lines := append([]string(nil), l.lines...)
	if rest := strings.TrimSpace(string(l.partial)); rest != "" {
		lines = append(lines, rest)
	}
	return strings.Join(lines, "\n")
}
