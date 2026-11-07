//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

// The x64 Visual C++ runtime files the bundled Java runtime needs, and the oldest usable
// version: the Visual C++ 14.40 toolset that built Temurin 21.0.13.
var (
	visualCppFiles = []string{"vcruntime140.dll", "vcruntime140_1.dll", "msvcp140.dll"}
	minimumRuntime = fileVersion{14, 40, 33810, 0}
)

var (
	kernel32                   = syscall.NewLazyDLL("kernel32.dll")
	versionDLL                 = syscall.NewLazyDLL("version.dll")
	shell32                    = syscall.NewLazyDLL("shell32.dll")
	procGetSystemDirectory     = kernel32.NewProc("GetSystemDirectoryW")
	procSetConsoleTitle        = kernel32.NewProc("SetConsoleTitleW")
	procSetConsoleMode         = kernel32.NewProc("SetConsoleMode")
	procGetFileVersionInfoSize = versionDLL.NewProc("GetFileVersionInfoSizeW")
	procGetFileVersionInfo     = versionDLL.NewProc("GetFileVersionInfoW")
	procVerQueryValue          = versionDLL.NewProc("VerQueryValueW")
	procShellExecute           = shell32.NewProc("ShellExecuteW")
	procCreateMutex            = kernel32.NewProc("CreateMutexW")
)

// holdInstanceMutex creates the "OfficeFlow.Launcher" mutex for as long as this process runs.
// The installer's AppMutex setting uses it to ask the user to close OfficeFlow before an
// upgrade or uninstall, instead of replacing files under a running Java.
func holdInstanceMutex() {
	if name, err := syscall.UTF16PtrFromString("OfficeFlow.Launcher"); err == nil {
		procCreateMutex.Call(0, 0, uintptr(unsafe.Pointer(name)))
	}
}

type fileVersion [4]uint16

func (v fileVersion) String() string {
	return fmt.Sprintf("%d.%d.%d.%d", v[0], v[1], v[2], v[3])
}

func (v fileVersion) less(other fileVersion) bool {
	for i := range v {
		if v[i] != other[i] {
			return v[i] < other[i]
		}
	}
	return false
}

// VS_FIXEDFILEINFO from the Windows SDK.
type fixedFileInfo struct {
	Signature, StrucVersion, FileVersionMS, FileVersionLS     uint32
	ProductVersionMS, ProductVersionLS, FileFlagsMask         uint32
	FileFlags, FileOS, FileType, FileSubtype, FileDateMS, FileDateLS uint32
}

// checkVisualCpp returns a description of the problem, or "" when the runtime in directory is usable.
func checkVisualCpp(directory string) string {
	for _, name := range visualCppFiles {
		path := filepath.Join(directory, name)
		if !exists(path) {
			return name + " is not installed."
		}
		version, err := readFileVersion(path)
		if err != nil {
			return name + " could not be checked (" + err.Error() + ")."
		}
		if version.less(minimumRuntime) {
			return fmt.Sprintf("%s is version %s; version %s or newer is needed.", name, version, minimumRuntime)
		}
	}
	return ""
}

func readFileVersion(path string) (fileVersion, error) {
	name, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return fileVersion{}, err
	}
	size, _, _ := procGetFileVersionInfoSize.Call(uintptr(unsafe.Pointer(name)), 0)
	if size == 0 {
		return fileVersion{}, errors.New("no version information")
	}
	buffer := make([]byte, size)
	ok, _, _ := procGetFileVersionInfo.Call(uintptr(unsafe.Pointer(name)), 0, size, uintptr(unsafe.Pointer(&buffer[0])))
	if ok == 0 {
		return fileVersion{}, errors.New("version information unreadable")
	}
	root, _ := syscall.UTF16PtrFromString(`\`)
	var info *fixedFileInfo
	var length uint32
	ok, _, _ = procVerQueryValue.Call(uintptr(unsafe.Pointer(&buffer[0])), uintptr(unsafe.Pointer(root)),
		uintptr(unsafe.Pointer(&info)), uintptr(unsafe.Pointer(&length)))
	if ok == 0 || info == nil || uintptr(length) < unsafe.Sizeof(fixedFileInfo{}) {
		return fileVersion{}, errors.New("no file version")
	}
	version := fileVersion{
		uint16(info.FileVersionMS >> 16), uint16(info.FileVersionMS & 0xFFFF),
		uint16(info.FileVersionLS >> 16), uint16(info.FileVersionLS & 0xFFFF),
	}
	runtime.KeepAlive(buffer)
	return version, nil
}

// systemDirectory is the 64-bit System32 folder (OfficeFlow.exe is an x64 program).
func systemDirectory() string {
	buffer := make([]uint16, 512)
	n, _, _ := procGetSystemDirectory.Call(uintptr(unsafe.Pointer(&buffer[0])), uintptr(len(buffer)))
	if n == 0 || int(n) >= len(buffer) {
		return filepath.Join(os.Getenv("SystemRoot"), "System32")
	}
	return syscall.UTF16ToString(buffer[:n])
}

func setConsoleTitle(title string) {
	if text, err := syscall.UTF16PtrFromString(title); err == nil {
		procSetConsoleTitle.Call(uintptr(unsafe.Pointer(text)))
	}
}

func stdinIsConsole() bool {
	var mode uint32
	return syscall.GetConsoleMode(syscall.Stdin, &mode) == nil
}

// hideConsoleInput turns off echo for the console input and returns a function that restores it.
func hideConsoleInput() func() {
	const enableEchoInput = 0x0004
	var mode uint32
	if syscall.GetConsoleMode(syscall.Stdin, &mode) != nil {
		return func() {}
	}
	procSetConsoleMode.Call(uintptr(syscall.Stdin), uintptr(mode&^enableEchoInput))
	return func() { procSetConsoleMode.Call(uintptr(syscall.Stdin), uintptr(mode)) }
}

// shellOpen opens a URL in the default browser through the Windows shell (no cmd.exe).
func shellOpen(url string) {
	verb, _ := syscall.UTF16PtrFromString("open")
	target, err := syscall.UTF16PtrFromString(url)
	if err != nil {
		return
	}
	const showNormal = 1
	procShellExecute.Call(0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(target)), 0, 0, showNormal)
}
