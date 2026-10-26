//go:build windows

package main

import (
	"context"
	"fmt"
	"io/fs"
	"path/filepath"
	"time"

	"golang.org/x/sys/windows"
)

const recycleReviewTimeout = 10 * time.Second
const recycleReviewMaxEntries = 100000

type recycleIdentity struct {
	volume     uint32
	high       uint32
	low        uint32
	attributes uint32
}

func readRecycleIdentity(path string) (recycleIdentity, error) {
	p, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return recycleIdentity{}, err
	}
	h, err := windows.CreateFile(p, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE|windows.FILE_SHARE_DELETE,
		nil, windows.OPEN_EXISTING, windows.FILE_FLAG_BACKUP_SEMANTICS|windows.FILE_FLAG_OPEN_REPARSE_POINT, 0)
	if err != nil {
		return recycleIdentity{}, err
	}
	defer func() {
		// This handle only reads metadata: there are no writes to flush, and a
		// close error does not invalidate the identity already read from it.
		_ = windows.CloseHandle(h)
	}()
	var info windows.ByHandleFileInformation
	if err := windows.GetFileInformationByHandle(h, &info); err != nil {
		return recycleIdentity{}, err
	}
	return recycleIdentity{info.VolumeSerialNumber, info.FileIndexHigh, info.FileIndexLow, info.FileAttributes}, nil
}

// Bind every ancestor and the selected item without following a reparse point.
// The selected leaf may be a link; recycling it does not traverse its target.
func recycleIdentityChain(path string) (map[string]recycleIdentity, error) {
	chain := make(map[string]recycleIdentity)
	for current := filepath.Clean(path); ; current = filepath.Dir(current) {
		id, err := readRecycleIdentity(current)
		if err != nil {
			return nil, fmt.Errorf("cannot inspect %s: %w", current, err)
		}
		if current != filepath.Clean(path) && id.attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 {
			return nil, fmt.Errorf("cannot recycle through a linked ancestor: %s", current)
		}
		chain[current] = id
		if parent := filepath.Dir(current); parent == current {
			break
		}
	}
	return chain, nil
}

func checkRecycleTree(path string) error {
	ctx, cancel := context.WithTimeout(context.Background(), recycleReviewTimeout)
	defer cancel()
	count := 0
	return filepath.WalkDir(path, func(current string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := ctx.Err(); err != nil {
			return fmt.Errorf("recycle review incomplete: %w", err)
		}
		count++
		if count > recycleReviewMaxEntries {
			return fmt.Errorf("recycle review incomplete: too many entries")
		}
		if isProtectedPath(current) {
			return fmt.Errorf("protected path cannot be deleted: %s", current)
		}
		// WalkDir does not follow directory links. Explicitly stop at every reparse
		// directory too, including non-name-surrogate providers we cannot classify.
		id, err := readRecycleIdentity(current)
		if err != nil {
			return err
		}
		if id.attributes&windows.FILE_ATTRIBUTE_REPARSE_POINT != 0 && entry.IsDir() {
			return fmt.Errorf("cannot inspect reparse directory: %s", current)
		}
		return nil
	})
}

func prepareRecycleTarget(path string) (func() error, error) {
	chain, err := recycleIdentityChain(path)
	if err != nil {
		return nil, err
	}
	if err := checkRecycleTree(path); err != nil {
		return nil, err
	}
	return func() error {
		if err := checkRecycleTree(path); err != nil {
			return err
		}
		current, err := recycleIdentityChain(path)
		if err != nil {
			return err
		}
		if len(current) != len(chain) {
			return fmt.Errorf("recycle target changed: %s", path)
		}
		for name, id := range chain {
			if current[name] != id {
				return fmt.Errorf("recycle target changed: %s", name)
			}
		}
		return nil
	}, nil
}
