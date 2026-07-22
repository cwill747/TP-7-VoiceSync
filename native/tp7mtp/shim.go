// Package main builds a C-shared library (libtp7mtp) exposing a session-
// based MTP interface for reading TP-7 voice recordings.
//
// A single MTP session must be opened once (tp7mtp_open) and reused for
// every list/download/delete call, then closed once (tp7mtp_close). The
// TP-7's MTP firmware does not tolerate rapid open/close churn - opening
// and tearing down a session per file transfer was observed to crash the
// device out of MTP mode entirely.
package main

/*
#include <stdlib.h>

// Reports bytes transferred for the file currently being downloaded.
// Invoked synchronously, possibly many times, from within
// tp7mtp_download_recording - never after it returns. context is an opaque
// pointer the caller supplied to tp7mtp_download_recording and is passed
// back unchanged.
typedef void (*tp7mtp_progress_cb)(long long bytesSent, long long bytesTotal, void *context);

// cgo cannot invoke a C function pointer directly from Go, so this trampoline
// does it on Go's behalf.
static inline void tp7mtp_invoke_progress_cb(tp7mtp_progress_cb cb, long long bytesSent, long long bytesTotal, void *context) {
    if (cb != NULL) {
        cb(bytesSent, bytesTotal, context);
    }
}
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	mtpx "github.com/ganeshrvel/go-mtpx"
	"github.com/ganeshrvel/usb"
)

// The TP-7 can split recordings between two on-device folders depending on
// how the user has it configured; ingest both, keyed by this label so
// download/delete calls know which device directory a filename lives in.
const (
	folderRecordings = "recordings"
	folderMemo       = "memo"
)

var recordingDirs = map[string]string{
	folderRecordings: "/recordings",
	folderMemo:       "/memo",
}

// Matches mtpx's internal devTimeout (milliseconds).
const usbTimeoutMs = 15000

// Only allow connections to Teenage Engineering TP-7 devices.
const allowedManufacturer = "teenage engineering"
const allowedModel = "TP-7"

type deviceInfo struct {
	Manufacturer string `json:"manufacturer"`
	Model        string `json:"model"`
	Serial       string `json:"serial"`
}

type fileEntry struct {
	Name    string `json:"name"`
	Folder  string `json:"folder"`
	Size    int64  `json:"size"`
	ModTime int64  `json:"modTime"`
}

type response struct {
	OK     bool        `json:"ok"`
	Error  string      `json:"error,omitempty"`
	Handle int         `json:"handle,omitempty"`
	Device *deviceInfo `json:"device,omitempty"`
	Files  []fileEntry `json:"files,omitempty"`
}

func toCString(r response) *C.char {
	b, err := json.Marshal(r)
	if err != nil {
		return C.CString(`{"ok":false,"error":"internal: failed to encode response"}`)
	}
	return C.CString(string(b))
}

func errResponse(format string, args ...interface{}) response {
	return response{OK: false, Error: fmt.Sprintf(format, args...)}
}

type session struct {
	dev       *mtp.Device
	storageID uint32

	// Guards every device I/O call made through this session. The TP-7's MTP
	// firmware does not tolerate two USB conversations interleaving on one
	// connection (session churn crashes it out of MTP mode), so list/
	// download/delete calls - which may be invoked from concurrent Swift
	// Task.detached closures - must be serialized here.
	ioMu sync.Mutex

	// Set under ioMu once the session has been disposed. sessionsMu only
	// protects the handle->session map, so a close can run concurrently with
	// a lookup that already read the map entry; checking this flag after
	// acquiring ioMu prevents that lookup from touching a disposed device.
	closed bool
}

var (
	sessionsMu sync.Mutex
	sessions   = map[int]*session{}
	nextHandle = 1
)

// libusb allocates a pthread TLS key each time a context is created
// (usbi_tls_key_create -> pthread_key_create) and only releases it on
// libusb_exit. The upstream go-mtpfs SelectDevice* helpers create a fresh
// context on every call and never call libusb_exit, so the app's connect
// polling leaked one TLS key per attempt and eventually aborted the whole
// process once PTHREAD_KEYS_MAX (~512 on macOS) was exhausted:
//
//	Assertion failed: (pthread_key_create(key, ((void*)0)) == 0),
//	function usbi_tls_key_create, file threads_posix.h, line 81.
//
// We create a single process-wide context and reuse it for every connect
// attempt, so exactly one TLS key is ever allocated.
var (
	usbCtxMu sync.Mutex
	usbCtx   *usb.Context
)

func sharedUSBContext() *usb.Context {
	usbCtxMu.Lock()
	defer usbCtxMu.Unlock()
	if usbCtx == nil {
		usbCtx = usb.NewContext()
	}
	return usbCtx
}

// openDevice mirrors mtpx.Initialize (find -> open -> configure) but reuses the
// shared libusb context instead of allocating a new one per call. It opens the
// first MTP device it finds and releases the usb references of any others.
func openDevice() (*mtp.Device, error) {
	cands, err := mtp.FindDevices(sharedUSBContext())
	if err != nil {
		return nil, err
	}

	var dev *mtp.Device
	for _, cand := range cands {
		if dev == nil && cand.Open() == nil {
			dev = cand
			continue
		}
		// Release the usb device reference FindDevices took for candidates we
		// don't use (unopened or extra devices).
		cand.Done()
	}
	if dev == nil {
		return nil, fmt.Errorf("no MTP devices found")
	}

	dev.MTPDebug = false
	dev.DataDebug = false
	dev.USBDebug = false
	dev.Timeout = usbTimeoutMs

	if err := dev.Configure(); err != nil {
		disposeDevice(dev)
		return nil, err
	}
	return dev, nil
}

// disposeDevice closes the MTP session and releases the underlying usb device
// reference. Replaces mtpx.Dispose, which only calls Close (leaking the ref).
func disposeDevice(dev *mtp.Device) {
	dev.Close()
	dev.Done()
}

func withSession(handle int, fn func(dev *mtp.Device, storageID uint32) error) error {
	sessionsMu.Lock()
	s, ok := sessions[handle]
	sessionsMu.Unlock()
	if !ok {
		return fmt.Errorf("invalid or closed session handle %d", handle)
	}
	s.ioMu.Lock()
	defer s.ioMu.Unlock()
	if s.closed {
		return fmt.Errorf("invalid or closed session handle %d", handle)
	}
	return fn(s.dev, s.storageID)
}

// localizeWallClock corrects timestamps for MTP devices (the TP-7 included)
// that report object dates as bare wall-clock time with no UTC offset, e.g.
// "20260706T080000". go-mtpfs's PTP date decoder (mtp/encoding.go decodeTime)
// has no zone to work with in that case, and Go's time.Parse silently
// defaults an unspecified zone to UTC - so a recording made at 8am local
// comes back as 8am UTC, off by exactly the host's UTC offset. Devices that
// do send an explicit numeric offset parse into a non-UTC Location already
// and are left untouched here.
func localizeWallClock(t time.Time) time.Time {
	if t.IsZero() || t.Location() != time.UTC {
		return t
	}
	return time.Date(t.Year(), t.Month(), t.Day(), t.Hour(), t.Minute(), t.Second(), t.Nanosecond(), time.Local)
}

// isSafeRecordingName reports whether name is safe to join onto a device
// recording directory or a local destination directory: no path separators,
// and not a "." or ".." traversal segment. The TP-7 only ever reports flat
// filenames under /recordings or /memo, so anything else is either a
// firmware bug or a hostile device.
func isSafeRecordingName(name string) bool {
	if name == "" || name == "." || name == ".." {
		return false
	}
	return name == filepath.Base(name)
}

//export tp7mtp_open
func tp7mtp_open() *C.char {
	dev, err := openDevice()
	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}

	info, err := mtpx.FetchDeviceInfo(dev)
	if err != nil {
		disposeDevice(dev)
		return toCString(errResponse("%s", err.Error()))
	}

	// Reject non-TP-7 devices to avoid interacting with unrelated MTP hardware.
	if !strings.EqualFold(info.Manufacturer, allowedManufacturer) ||
		!strings.Contains(info.Model, allowedModel) {
		disposeDevice(dev)
		return toCString(errResponse("connected MTP device is not a TP-7 (got %s %s)", info.Manufacturer, info.Model))
	}

	storages, err := mtpx.FetchStorages(dev)
	if err != nil {
		disposeDevice(dev)
		return toCString(errResponse("%s", err.Error()))
	}
	if len(storages) == 0 {
		disposeDevice(dev)
		return toCString(errResponse("no storage found on device"))
	}

	sessionsMu.Lock()
	handle := nextHandle
	nextHandle++
	sessions[handle] = &session{dev: dev, storageID: storages[0].Sid}
	sessionsMu.Unlock()

	return toCString(response{
		OK:     true,
		Handle: handle,
		Device: &deviceInfo{
			Manufacturer: info.Manufacturer,
			Model:        info.Model,
			Serial:       info.SerialNumber,
		},
	})
}

//export tp7mtp_close
func tp7mtp_close(handle int) {
	sessionsMu.Lock()
	s, ok := sessions[handle]
	delete(sessions, handle)
	sessionsMu.Unlock()

	if ok {
		// Wait for any in-flight list/download/delete call on this session to
		// finish before tearing down the device. withSession re-checks
		// s.closed after acquiring ioMu, so a call that read the (now
		// removed) map entry just before this runs will still see the
		// disposal and refuse to touch the device.
		s.ioMu.Lock()
		s.closed = true
		disposeDevice(s.dev)
		s.ioMu.Unlock()
	}
}

//export tp7mtp_list_recordings
func tp7mtp_list_recordings(handle int) *C.char {
	var files []fileEntry

	err := withSession(handle, func(dev *mtp.Device, storageID uint32) error {
		for _, folder := range []string{folderRecordings, folderMemo} {
			dirPath := recordingDirs[folder]
			_, _, _, err := mtpx.Walk(dev, storageID, dirPath, false, true, true,
				func(objectID uint32, fi *mtpx.FileInfo, err error) error {
					if err != nil {
						return err
					}
					if fi.IsDir {
						return nil
					}
					name := fi.Name
					if strings.HasPrefix(name, ".") || !strings.HasSuffix(strings.ToLower(name), ".wav") {
						return nil
					}
					if !isSafeRecordingName(name) {
						fmt.Fprintf(os.Stderr, "tp7mtp: skipping recording with unsafe filename %q\n", name)
						return nil
					}
					files = append(files, fileEntry{
						Name:    name,
						Folder:  folder,
						Size:    fi.Size,
						ModTime: localizeWallClock(fi.ModTime).Unix(),
					})
					return nil
				})
			if err != nil {
				// Not every device/firmware splits recordings into both
				// folders - a missing one is not fatal, just empty.
				if _, isMissingPath := err.(mtpx.InvalidPathError); isMissingPath {
					continue
				}
				return fmt.Errorf("listing %s: %w", dirPath, err)
			}
		}
		return nil
	})

	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}
	return toCString(response{OK: true, Files: files})
}

//export tp7mtp_download_recording
func tp7mtp_download_recording(handle int, cFolder *C.char, cFilename *C.char, cDestPath *C.char, progressCb C.tp7mtp_progress_cb, progressContext unsafe.Pointer) *C.char {
	folder := C.GoString(cFolder)
	filename := C.GoString(cFilename)
	destPath := C.GoString(cDestPath)
	dirPath, ok := recordingDirs[folder]
	if !ok {
		return toCString(errResponse("unknown recording folder %q", folder))
	}
	if !isSafeRecordingName(filename) {
		return toCString(errResponse("unsafe filename %q", filename))
	}
	sourcePath := dirPath + "/" + filename

	var modTime time.Time

	err := withSession(handle, func(dev *mtp.Device, storageID uint32) error {
		destDir := filepath.Dir(destPath)
		if err := os.MkdirAll(destDir, 0o755); err != nil {
			return err
		}

		tmpDestDir, err := os.MkdirTemp(destDir, ".tp7mtp-download-*")
		if err != nil {
			return err
		}
		defer os.RemoveAll(tmpDestDir)

		_, _, err = mtpx.DownloadFiles(dev, storageID, []string{sourcePath}, tmpDestDir, false,
			func(fi *mtpx.FileInfo, err error) error { return err },
			func(pi *mtpx.ProgressInfo, err error) error {
				if pi.FileInfo != nil {
					modTime = pi.FileInfo.ModTime
				}
				if pi.ActiveFileSize != nil {
					C.tp7mtp_invoke_progress_cb(progressCb, C.longlong(pi.ActiveFileSize.Sent), C.longlong(pi.ActiveFileSize.Total), progressContext)
				}
				return err
			},
		)
		if err != nil {
			return err
		}

		downloadedPath := filepath.Join(tmpDestDir, filename)
		if err := os.Rename(downloadedPath, destPath); err != nil {
			return err
		}

		// mtpx stamped the file's mtime with the device-reported ModTime during
		// DownloadFiles above (restoreLocalFileTimestamp), which for the TP-7
		// is the wall-clock-mislabeled-as-UTC value described in
		// localizeWallClock. SyncService reads this file's mtime as the
		// recording's recordedAt, so re-stamp it with the corrected time.
		if corrected := localizeWallClock(modTime); !corrected.IsZero() {
			_ = os.Chtimes(destPath, corrected, corrected)
		}

		return nil
	})

	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}
	return toCString(response{OK: true})
}

//export tp7mtp_delete_recording
func tp7mtp_delete_recording(handle int, cFolder *C.char, cFilename *C.char) *C.char {
	folder := C.GoString(cFolder)
	filename := C.GoString(cFilename)
	dirPath, ok := recordingDirs[folder]
	if !ok {
		return toCString(errResponse("unknown recording folder %q", folder))
	}
	if !isSafeRecordingName(filename) {
		return toCString(errResponse("unsafe filename %q", filename))
	}
	fullPath := dirPath + "/" + filename

	err := withSession(handle, func(dev *mtp.Device, storageID uint32) error {
		return mtpx.DeleteFile(dev, storageID, []mtpx.FileProp{{FullPath: fullPath}})
	})

	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}
	return toCString(response{OK: true})
}

//export tp7mtp_free
func tp7mtp_free(s *C.char) {
	C.free(unsafe.Pointer(s))
}

func main() {}
