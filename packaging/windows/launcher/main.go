//go:build windows

// OfficeFlow.exe starts OfficeFlow from the Windows ZIP. It checks the Microsoft Visual C++
// runtime, asks for the first administrator password with hidden input, starts the bundled Java
// runtime, opens the browser when the server answers and waits until OfficeFlow stops.
// Its only child process is runtime\bin\java.exe; it never starts cmd.exe or PowerShell.
package main

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	serverURL          = "http://127.0.0.1:8080/"
	redistributablePage = "https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist"
	ctrlCExit          = 0xC000013A // STATUS_CONTROL_C_EXIT
)

func main() {
	os.Exit(run())
}

func run() int {
	setConsoleTitle("OfficeFlow")
	executable, err := os.Executable()
	if err != nil {
		return fail("OfficeFlow could not find its own folder: %v", err)
	}
	if resolved, err := filepath.EvalSymlinks(executable); err == nil {
		executable = resolved
	}
	root := filepath.Dir(executable)
	java := filepath.Join(root, "runtime", "bin", "java.exe")
	jar := filepath.Join(root, "app", "officeflow.jar")
	site := filepath.Join(root, "app", "site")

	if !exists(java) {
		return fail("The Java runtime is missing from this folder:\n  %s\n"+
			"Extract the whole OfficeFlow ZIP again, then start OfficeFlow.exe from the extracted folder.", java)
	}
	if !exists(jar) || !exists(filepath.Join(site, "index.html")) {
		return fail("Some OfficeFlow files are missing from:\n  %s\n"+
			"Extract the whole OfficeFlow ZIP again. Do not run OfficeFlow from inside the ZIP.", root)
	}
	if problem := checkVisualCpp(systemDirectory()); problem != "" {
		openBrowser(redistributablePage)
		return fail("OfficeFlow needs the Microsoft Visual C++ Redistributable for Visual Studio 2015-2022 (x64), "+
			"version 14.40 or newer.\n%s\n\nDownload it from Microsoft's official page:\n  %s\n"+
			"Choose the X64 download (vc_redist.x64.exe), install it, then start OfficeFlow again.",
			problem, redistributablePage)
	}
	if officeFlowAnswers(2 * time.Second) {
		fmt.Println("OfficeFlow is already running. Opening " + serverURL)
		fmt.Println("Use the other OfficeFlow window to stop it.")
		openBrowser(serverURL)
		time.Sleep(3 * time.Second)
		return 0
	}

	database := filepath.Join(os.Getenv("LOCALAPPDATA"), "OfficeFlow", "officeflow.mv.db")
	environment := os.Environ()
	if !exists(database) && os.Getenv("OFFICEFLOW_ADMIN_PASSWORD") == "" {
		password, err := askNewPassword(bufio.NewReader(os.Stdin), stdinIsConsole())
		if err != nil {
			return fail("%v", err)
		}
		// Passed only in the child's environment: never on a command line or in output.
		environment = append(environment, "OFFICEFLOW_ADMIN_PASSWORD="+password)
	}

	fmt.Println()
	fmt.Println("Starting OfficeFlow. Your workspace: " + database)
	fmt.Println("Keep this window open while you use OfficeFlow. To stop it, press Ctrl+C or close this window.")
	fmt.Println()

	// Ctrl+C and closing the window reach Java too, which closes the database cleanly; the
	// launcher itself keeps waiting for Java instead of exiting first.
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)

	command := exec.Command(java, "-Dofficeflow.site="+site, "-jar", jar)
	command.Dir = root
	command.Env = environment
	command.Stdout = os.Stdout
	command.Stderr = os.Stderr
	if err := command.Start(); err != nil {
		return fail("OfficeFlow could not start Java: %v", err)
	}
	stopped := make(chan struct{})
	go openWhenReady(stopped)
	waitErr := command.Wait()
	close(stopped)

	code := 0
	if command.ProcessState != nil {
		code = command.ProcessState.ExitCode()
	} else if waitErr != nil {
		return fail("OfficeFlow stopped unexpectedly: %v", waitErr)
	}
	if code != 0 && code != 130 && uint32(code) != ctrlCExit {
		return fail("OfficeFlow stopped because of the problem shown above (exit code %d).", code)
	}
	fmt.Println("OfficeFlow has stopped. Your workspace is saved in " + database)
	return 0
}

// askNewPassword asks twice for the first administrator password, with echo off on a console.
func askNewPassword(input *bufio.Reader, console bool) (string, error) {
	fmt.Println("Welcome to OfficeFlow. This is the first start for this Windows account.")
	fmt.Println("Choose a password for the administrator account (ID 001). Use 12-120 characters.")
	fmt.Println("Typing is hidden. Keep this password safe; it is needed to manage OfficeFlow.")
	for attempt := 0; attempt < 3; attempt++ {
		first, err := readSecret("New admin password: ", input, console)
		if err != nil {
			break
		}
		second, err := readSecret("Type it again: ", input, console)
		if err != nil {
			break
		}
		if first != second {
			fmt.Println("The passwords do not match. Try again.")
			continue
		}
		if !validPassword(first) {
			fmt.Println("Use 12-120 characters. Try again.")
			continue
		}
		return first, nil
	}
	return "", errors.New("No administrator password was set, so no workspace was created. " +
		"Start OfficeFlow again to retry.")
}

func readSecret(prompt string, input *bufio.Reader, console bool) (string, error) {
	fmt.Print(prompt)
	if console {
		restore := hideConsoleInput()
		defer func() {
			restore()
			fmt.Println()
		}()
	}
	line, err := input.ReadString('\n')
	if err != nil && !(errors.Is(err, io.EOF) && line != "") {
		return "", err
	}
	return strings.TrimRight(line, "\r\n"), nil
}

// validPassword matches the server's policy: 12-120 UTF-16 code units and not only spaces.
func validPassword(password string) bool {
	units := 0
	for _, r := range password {
		if r > 0xFFFF {
			units += 2
		} else {
			units++
		}
	}
	return units >= 12 && units <= 120 && strings.TrimSpace(password) != ""
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

func openWhenReady(stopped <-chan struct{}) {
	for i := 0; i < 120; i++ {
		select {
		case <-stopped:
			return
		case <-time.After(500 * time.Millisecond):
		}
		if officeFlowAnswers(time.Second) {
			openBrowser(serverURL)
			return
		}
	}
}

func openBrowser(url string) {
	if os.Getenv("OFFICEFLOW_NO_BROWSER") != "" {
		return
	}
	shellOpen(url)
}

func exists(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func fail(format string, arguments ...any) int {
	fmt.Println()
	fmt.Printf(format+"\n", arguments...)
	if stdinIsConsole() {
		fmt.Println()
		fmt.Println("Press Enter to close this window.")
		bufio.NewReader(os.Stdin).ReadString('\n')
	}
	return 1
}
