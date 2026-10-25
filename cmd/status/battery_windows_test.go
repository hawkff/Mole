//go:build windows

package main

import (
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

func TestBatteryNativeQueryBoundaries(t *testing.T) {
	for _, tc := range []struct {
		name                             string
		tag, tagBytes                    uint32
		tagErr                           error
		infoBytes                        uint32
		infoErr                          error
		capabilities                     uint32
		wantError, wantPresent, wantInfo bool
	}{
		{name: "empty bay", tagErr: windows.ERROR_FILE_NOT_FOUND},
		{name: "stale tag with missing device", tag: 7, tagErr: windows.ERROR_FILE_NOT_FOUND, wantError: true},
		{name: "tag access denied", tagErr: windows.ERROR_ACCESS_DENIED, wantError: true},
		{name: "successful invalid tag", tagBytes: 4, wantError: true},
		{name: "short tag", tag: 7, tagBytes: 2, wantError: true},
		{name: "hot removal after tag", tag: 7, tagBytes: 4, infoErr: windows.ERROR_FILE_NOT_FOUND, wantError: true, wantInfo: true},
		{name: "short information", tag: 7, tagBytes: 4, infoBytes: 4, wantError: true, wantInfo: true},
		{name: "system battery", tag: 7, tagBytes: 4, infoBytes: uint32(unsafe.Sizeof(batteryInformation{})), capabilities: 0x80000000, wantPresent: true, wantInfo: true},
		{name: "peripheral battery", tag: 7, tagBytes: 4, infoBytes: uint32(unsafe.Sizeof(batteryInformation{})), wantInfo: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			queried := false
			got, err := queryBatteryDeviceHealth(func(tag, returned *uint32) error {
				*tag = tc.tag
				*returned = tc.tagBytes
				return tc.tagErr
			}, func(tag uint32, info *batteryInformation, returned *uint32) error {
				queried = true
				if tag != 7 {
					t.Fatalf("query used tag %d", tag)
				}
				info.Capabilities = tc.capabilities
				info.DesignedCapacity = 50000
				info.FullChargedCapacity = 40000
				info.CycleCount = 100
				*returned = tc.infoBytes
				return tc.infoErr
			})
			if (err != nil) != tc.wantError || got.present != tc.wantPresent || queried != tc.wantInfo {
				t.Fatalf("sample=%+v err=%v information queried=%v", got, err, queried)
			}
			if got.present && (got.design != 50000 || got.full != 40000 || got.cycles != 100) {
				t.Fatalf("incomplete sample: %+v", got)
			}
		})
	}
}
