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
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"github.com/ganeshrvel/go-mtpfs/mtp"
	mtpx "github.com/ganeshrvel/go-mtpx"
)

const recordingsDir = "/recordings"

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
}

var (
	sessionsMu sync.Mutex
	sessions   = map[int]*session{}
	nextHandle = 1
)

func withSession(handle int, fn func(dev *mtp.Device, storageID uint32) error) error {
	sessionsMu.Lock()
	s, ok := sessions[handle]
	sessionsMu.Unlock()
	if !ok {
		return fmt.Errorf("invalid or closed session handle %d", handle)
	}
	return fn(s.dev, s.storageID)
}

//export tp7mtp_open
func tp7mtp_open() *C.char {
	dev, err := mtpx.Initialize(mtpx.Init{DebugMode: false})
	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}

	info, err := mtpx.FetchDeviceInfo(dev)
	if err != nil {
		mtpx.Dispose(dev)
		return toCString(errResponse("%s", err.Error()))
	}

	// Reject non-TP-7 devices to avoid interacting with unrelated MTP hardware.
	if !strings.EqualFold(info.Manufacturer, allowedManufacturer) ||
		!strings.Contains(info.Model, allowedModel) {
		mtpx.Dispose(dev)
		return toCString(errResponse("connected MTP device is not a TP-7 (got %s %s)", info.Manufacturer, info.Model))
	}

	storages, err := mtpx.FetchStorages(dev)
	if err != nil {
		mtpx.Dispose(dev)
		return toCString(errResponse("%s", err.Error()))
	}
	if len(storages) == 0 {
		mtpx.Dispose(dev)
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
		mtpx.Dispose(s.dev)
	}
}

//export tp7mtp_list_recordings
func tp7mtp_list_recordings(handle int) *C.char {
	var files []fileEntry

	err := withSession(handle, func(dev *mtp.Device, storageID uint32) error {
		_, _, _, err := mtpx.Walk(dev, storageID, recordingsDir, false, true, true,
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
				files = append(files, fileEntry{
					Name:    name,
					Size:    fi.Size,
					ModTime: fi.ModTime.Unix(),
				})
				return nil
			})
		return err
	})

	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}
	return toCString(response{OK: true, Files: files})
}

//export tp7mtp_download_recording
func tp7mtp_download_recording(handle int, cFilename *C.char, cDestPath *C.char) *C.char {
	filename := C.GoString(cFilename)
	destPath := C.GoString(cDestPath)
	sourcePath := recordingsDir + "/" + filename

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
			func(pi *mtpx.ProgressInfo, err error) error { return err },
		)
		if err != nil {
			return err
		}

		downloadedPath := filepath.Join(tmpDestDir, filename)
		return os.Rename(downloadedPath, destPath)
	})

	if err != nil {
		return toCString(errResponse("%s", err.Error()))
	}
	return toCString(response{OK: true})
}

//export tp7mtp_delete_recording
func tp7mtp_delete_recording(handle int, cFilename *C.char) *C.char {
	filename := C.GoString(cFilename)
	fullPath := recordingsDir + "/" + filename

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
