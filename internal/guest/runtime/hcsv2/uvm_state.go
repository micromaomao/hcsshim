//go:build linux
// +build linux

package hcsv2

import (
	"fmt"
	"path/filepath"
	"strings"
	"sync"
)

type device struct {
	// fields common to all
	mountPath  string
	usage      int
	sourcePath string

	// rw devices
	encrypted bool
}

type hostMounts struct {
	stateMutex sync.Mutex

	// Map from mountPath to device struct
	devices map[string]*device
}

func newHostMounts() *hostMounts {
	return &hostMounts{
		devices: make(map[string]*device),
	}
}

// must hold hm.stateMutex
func (hm *hostMounts) findDeviceAtPath(mountPath string) *device {
	if dev, ok := hm.devices[mountPath]; ok {
		return dev
	}
	return nil
}

// must hold hm.stateMutex
func (hm *hostMounts) addDeviceToMapChecked(dev *device) error {
	if _, ok := hm.devices[dev.mountPath]; ok {
		return fmt.Errorf("device at mount path %q already exists", dev.mountPath)
	}
	hm.devices[dev.mountPath] = dev
	return nil
}

// must hold hm.stateMutex
func (hm *hostMounts) findDeviceContainingPath(path string) *device {
	// TODO: can we refactor this function by walking each component of the path
	// from leaf to root, each time checking if the current component is a mount
	// point?  (i.e. why do we have to use filepath.Rel?)

	var foundDev *device
	cleanPath := filepath.Clean(path)
	for devPath, dev := range hm.devices {
		relPath, err := filepath.Rel(devPath, cleanPath)
		// skip further checks if an error is returned or the relative path
		// contains "..", meaning that the `path` isn't directly nested under
		// `rwPath`.
		if err != nil || strings.HasPrefix(relPath, "..") {
			continue
		}
		if foundDev == nil {
			foundDev = dev
		} else if len(dev.mountPath) > len(foundDev.mountPath) {
			// The current device is mounted on top of a previously found device.
			foundDev = dev
		}
	}
	return foundDev
}

// AddRWDevice adds read-write device metadata for device mounted at `mountPath`.
// Returns an error if there's an existing device mounted at `mountPath` location.
func (hm *hostMounts) AddRWDevice(mountPath string, sourcePath string, encrypted bool) error {
	hm.stateMutex.Lock()
	defer hm.stateMutex.Unlock()

	dev := &device{
		mountPath:  filepath.Clean(mountPath),
		usage:      0,
		sourcePath: sourcePath,
		encrypted:  encrypted,
	}

	return hm.addDeviceToMapChecked(dev)
}

// RemoveRWDevice removes the read-write device metadata for device mounted at
// `mountPath`.
func (hm *hostMounts) RemoveRWDevice(mountPath string, sourcePath string) error {
	hm.stateMutex.Lock()
	defer hm.stateMutex.Unlock()

	unmountTarget := filepath.Clean(mountPath)
	device := hm.findDeviceAtPath(unmountTarget)
	if device == nil {
		// already removed or didn't exist
		return nil
	}
	if device.sourcePath != sourcePath {
		return fmt.Errorf("wrong sourcePath %s", sourcePath)
	}
	if device.usage > 0 {
		return fmt.Errorf("device at %q is still in use, can't unmount", unmountTarget)
	}

	delete(hm.devices, unmountTarget)
	return nil
}

// IsEncrypted checks if the given path is a sub-path of an encrypted read-write
// device.
func (hm *hostMounts) IsEncrypted(path string) bool {
	hm.stateMutex.Lock()
	defer hm.stateMutex.Unlock()

	dev := hm.findDeviceContainingPath(path)
	if dev == nil {
		return false
	}
	return dev.encrypted
}
