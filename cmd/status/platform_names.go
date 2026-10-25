package main

import (
	"errors"
	"fmt"
	"math"
	"regexp"
	"sort"
	"strings"
)

// normalizeDriveMount turns "c:" or "C:\" into the "C:\" form disk mounts use.
func normalizeDriveMount(drive string) string {
	drive = strings.TrimRight(strings.TrimSpace(drive), `\/`)
	if drive == "" {
		drive = "C:"
	}
	return strings.ToUpper(drive) + `\`
}

// sortDisksSystemFirst puts the system drive first: the health score and the
// header read disks[0] the way main reads the boot volume.
func sortDisksSystemFirst(disks []DiskStatus, system string) {
	sort.SliceStable(disks, func(i, j int) bool {
		si := strings.EqualFold(disks[i].Mount, system)
		sj := strings.EqualFold(disks[j].Mount, system)
		if si != sj {
			return si
		}
		return disks[i].Mount < disks[j].Mount
	})
}

// OEMs leave these in SMBIOS when they never filled the field in.
var placeholderModelNames = []string{
	"system product name", "system manufacturer", "to be filled by o.e.m.",
	"default string", "not applicable", "none", "o.e.m.", "oem",
}

func isPlaceholderModel(value string) bool {
	lower := strings.ToLower(strings.TrimSpace(value))
	if lower == "" {
		return true
	}
	for _, p := range placeholderModelNames {
		if lower == p {
			return true
		}
	}
	return false
}

// windowsModelName picks the readable machine name from the BIOS registry
// values, the counterpart of "MacBook Pro" in main's header. Lenovo stores a
// machine-type code in SystemProductName and the marketing name in
// SystemVersion, so that one vendor reads the version field instead.
func windowsModelName(manufacturer, product, version string) string {
	manufacturer = strings.TrimSpace(manufacturer)
	product = strings.TrimSpace(product)
	version = strings.TrimSpace(version)
	if strings.EqualFold(manufacturer, "LENOVO") && !isPlaceholderModel(version) {
		return version
	}
	if isPlaceholderModel(product) {
		return ""
	}
	return product
}

var (
	cpuTrademarkPattern = regexp.MustCompile(`(?i)\((r|tm)\)`)
	cpuClockPattern     = regexp.MustCompile(`(?i)\s*@\s*[\d.]+\s*[gm]hz`)
	cpuSuffixPattern    = regexp.MustCompile(`(?i)\s+(cpu|processor|\d+-core processor)$`)
)

// cleanCPUName shortens ProcessorNameString to the part main shows for a Mac
// chip: "Intel(R) Core(TM) i7-1165G7 @ 2.80GHz" becomes "Intel Core i7-1165G7".
func cleanCPUName(name string) string {
	name = cpuTrademarkPattern.ReplaceAllString(name, "")
	name = cpuClockPattern.ReplaceAllString(name, "")
	name = strings.Join(strings.Fields(name), " ")
	for {
		trimmed := cpuSuffixPattern.ReplaceAllString(name, "")
		if trimmed == name {
			break
		}
		name = trimmed
	}
	return strings.TrimSpace(strings.TrimSuffix(name, " CPU"))
}

// windowsOSVersion builds "Windows 11 24H2". The registry ProductName still
// says "Windows 10" on Windows 11, so the major version comes from the build.
func windowsOSVersion(build int, displayVersion string) string {
	if build <= 0 {
		return ""
	}
	name := "Windows 10"
	if build >= 22000 {
		name = "Windows 11"
	}
	if v := strings.TrimSpace(displayVersion); v != "" {
		return name + " " + v
	}
	return name
}

// windowsBatteryStatus maps GetSystemPowerStatus onto the status words main
// takes from pmset, so isPoweredByAC and formatBatteryStatus apply unchanged.
func windowsBatteryStatus(acLine, flag, percent byte) string {
	const batteryCharging = 8
	switch {
	case flag&batteryCharging != 0:
		return "charging"
	case acLine == 1 && percent >= 100:
		return "charged"
	case acLine == 1:
		return "AC"
	case acLine == 0:
		return "discharging"
	default:
		return "Unknown"
	}
}

// formatBatteryTimeLeft matches pmset's "h:mm". Windows reports the estimate in
// seconds only while discharging, and 0xFFFFFFFF when it has none.
func formatBatteryTimeLeft(seconds uint32) string {
	if seconds == math.MaxUint32 || seconds == 0 {
		return ""
	}
	return fmt.Sprintf("%d:%02d", seconds/3600, (seconds%3600)/60)
}

// batteryHealthPercent is full-charge capacity over design capacity, clamped
// to 0-100 like main's AppleSmartBattery reading.
func batteryHealthPercent(design, full int) int {
	if design <= 0 || full <= 0 {
		return 0
	}
	pct := math.Round(float64(full) * 100 / float64(design))
	return int(min(max(pct, 0), 100))
}

// Whole-machine charge and health must describe the same battery set. Unknown
// devices invalidate health; a successfully probed empty bay does not. Cycles
// show the oldest pack only when every count is known, never a sum.
type batteryHealthSample struct {
	present, relative    bool
	design, full, cycles int
}

func collectBatteryHealth(paths []string, read func(string) (batteryHealthSample, error)) (design, full, cycles int, err error) {
	present := false
	cyclesKnown := true
	capacityKnown := true
	for _, path := range paths {
		sample, readErr := read(path)
		if readErr != nil {
			return 0, 0, 0, readErr
		}
		if !sample.present {
			continue
		}
		if sample.relative || sample.design <= 0 || sample.full <= 0 ||
			sample.design == math.MaxUint32 || sample.full == math.MaxUint32 {
			capacityKnown = false
		}
		present = true
		design += sample.design
		full += sample.full
		cycles = max(cycles, sample.cycles)
		cyclesKnown = cyclesKnown && sample.cycles > 0
	}
	if !present {
		return 0, 0, 0, errors.New("no system battery")
	}
	if !capacityKnown {
		design, full = 0, 0
	}
	if !cyclesKnown {
		cycles = 0
	}
	return design, full, cycles, nil
}
