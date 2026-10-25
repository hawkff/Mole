//go:build windows

package main

import (
	"errors"
	"fmt"
	"os"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/shirou/gopsutil/v3/cpu"
	"github.com/shirou/gopsutil/v3/disk"
	"github.com/shirou/gopsutil/v3/mem"
	"github.com/shirou/gopsutil/v3/net"
	"golang.org/x/sys/windows"
	"golang.org/x/sys/windows/registry"
)

// Every reader here is an in-process Win32 call or registry read. Nothing
// spawns PowerShell or queries WMI, so the 1s refresh loop stays cheap.

var (
	modkernel32              = windows.NewLazySystemDLL("kernel32.dll")
	modpsapi                 = windows.NewLazySystemDLL("psapi.dll")
	moduser32                = windows.NewLazySystemDLL("user32.dll")
	procGetTickCount64       = modkernel32.NewProc("GetTickCount64")
	procGetSystemPowerStatus = modkernel32.NewProc("GetSystemPowerStatus")
	procGetPerformanceInfo   = modpsapi.NewProc("GetPerformanceInfo")
	procEnumDisplaySettingsW = moduser32.NewProc("EnumDisplaySettingsW")
)

func platformName() string {
	v := windows.RtlGetVersion()
	return fmt.Sprintf("windows %d.%d.%d", v.MajorVersion, v.MinorVersion, v.BuildNumber)
}

func readUptime() uint64 {
	ms, _, _ := procGetTickCount64.Call()
	return uint64(ms) / 1000
}

// --- CPU ---

var (
	cpuCountsOnce   sync.Once
	cpuPhysical     int
	cpuLogicalCount int
)

func cpuCounts() (physical, logical int) {
	cpuCountsOnce.Do(func() {
		if n, err := cpu.Counts(false); err == nil {
			cpuPhysical = n
		}
		if n, err := cpu.Counts(true); err == nil {
			cpuLogicalCount = n
		}
	})
	return cpuPhysical, cpuLogicalCount
}

// lastCPUSampleAt starts when gopsutil seeds its CPU baseline at package init.
var lastCPUSampleAt = time.Now()

// cpuSampleInterval is main's minimum usage window. Windows CPU times tick at
// the 15.6ms timer resolution, so a shorter window (the first sample of a
// one-shot --json run) reads per-core values in coarse steps.
const cpuSampleInterval = 100 * time.Millisecond

// readCPU reports usage since the previous call.
func readCPU() (CPUStatus, error) {
	if wait := cpuSampleInterval - time.Since(lastCPUSampleAt); wait > 0 {
		time.Sleep(wait)
	}
	defer func() { lastCPUSampleAt = time.Now() }()

	physical, logical := cpuCounts()
	percents, err := cpu.Percent(0, true)
	if err == nil && len(percents) > 0 {
		var total float64
		for _, v := range percents {
			total += v
		}
		if logical <= 0 {
			logical = len(percents)
		}
		return CPUStatus{
			Usage:      total / float64(len(percents)),
			PerCore:    percents,
			CoreCount:  physical,
			LogicalCPU: logical,
		}, nil
	}

	totals, totalErr := cpu.Percent(0, false)
	if totalErr != nil || len(totals) == 0 || logical <= 0 {
		if err == nil {
			err = totalErr
		}
		if err == nil {
			err = errors.New("cpu usage unavailable")
		}
		return CPUStatus{}, err
	}
	perCore := make([]float64, logical)
	for i := range perCore {
		perCore[i] = totals[0]
	}
	return CPUStatus{
		Usage:            totals[0],
		PerCore:          perCore,
		PerCoreEstimated: true,
		CoreCount:        physical,
		LogicalCPU:       logical,
	}, nil
}

// --- Memory ---

type performanceInformation struct {
	cb                uint32
	commitTotal       uintptr
	commitLimit       uintptr
	commitPeak        uintptr
	physicalTotal     uintptr
	physicalAvailable uintptr
	systemCache       uintptr
	kernelTotal       uintptr
	kernelPaged       uintptr
	kernelNonpaged    uintptr
	pageSize          uintptr
	handleCount       uint32
	processCount      uint32
	threadCount       uint32
}

// readMemory maps Windows memory onto main's card: Used and Available come
// from GlobalMemoryStatusEx, Cached is the system file cache Task Manager
// reports, and Swap is page file usage. Commit charge is deliberately not
// called swap: it counts reserved memory that may never touch the page file.
func readMemory() (MemoryStatus, error) {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return MemoryStatus{}, err
	}
	status := MemoryStatus{
		Used:      vm.Used,
		Total:     vm.Total,
		Available: vm.Available,
	}
	if vm.Total > 0 {
		status.UsedPercent = float64(vm.Used) / float64(vm.Total) * 100
	}

	if devices, err := mem.SwapDevices(); err == nil {
		for _, d := range devices {
			status.SwapUsed += d.UsedBytes
			status.SwapTotal += d.UsedBytes + d.FreeBytes
		}
	}

	var perf performanceInformation
	perf.cb = uint32(unsafe.Sizeof(perf))
	if ok, _, _ := procGetPerformanceInfo.Call(uintptr(unsafe.Pointer(&perf)), uintptr(perf.cb)); ok != 0 {
		status.Cached = uint64(perf.systemCache) * uint64(perf.pageSize)
	}
	return status, nil
}

// --- Disks ---

const (
	ioctlStorageQueryProperty = 0x2D1400
	storageBusTypeOffset      = 28 // STORAGE_DEVICE_DESCRIPTOR.BusType
	busType1394               = 4
	busTypeUSB                = 7
	busTypeSD                 = 12
	busTypeMMC                = 13
)

func systemDriveMount() string {
	return normalizeDriveMount(os.Getenv("SystemDrive"))
}

// localDrives lists fixed and removable drive roots. Network shares and
// optical drives are skipped before any volume call, so a disconnected share
// cannot stall the refresh.
func localDrives() []string {
	mask, err := windows.GetLogicalDrives()
	if err != nil {
		return nil
	}
	var roots []string
	for i := range 26 {
		if mask&(1<<uint(i)) == 0 {
			continue
		}
		root := string(rune('A'+i)) + `:\`
		ptr, err := windows.UTF16PtrFromString(root)
		if err != nil {
			continue
		}
		switch windows.GetDriveType(ptr) {
		case windows.DRIVE_FIXED, windows.DRIVE_REMOVABLE:
			roots = append(roots, root)
		}
	}
	return roots
}

func readDisks(external map[string]bool) ([]DiskStatus, error) {
	roots := localDrives()
	if len(roots) == 0 {
		return nil, errors.New("no local drives found")
	}
	var disks []DiskStatus
	for _, root := range roots {
		ptr, err := windows.UTF16PtrFromString(root)
		if err != nil {
			continue
		}
		var freeToCaller, total, totalFree uint64
		if err := windows.GetDiskFreeSpaceEx(ptr, &freeToCaller, &total, &totalFree); err != nil || total == 0 {
			continue // A removable drive with no media.
		}
		fsName := make([]uint16, windows.MAX_PATH+1)
		var fstype string
		if err := windows.GetVolumeInformation(ptr, nil, 0, nil, nil, nil, &fsName[0], uint32(len(fsName))); err == nil {
			fstype = windows.UTF16ToString(fsName)
		}
		used := total - min(totalFree, total)
		removable := windows.GetDriveType(ptr) == windows.DRIVE_REMOVABLE
		disks = append(disks, DiskStatus{
			Mount:       root,
			Device:      strings.TrimSuffix(root, `\`),
			Used:        used,
			Total:       total,
			UsedPercent: float64(used) / float64(total) * 100,
			Fstype:      fstype,
			External:    removable || external[root],
		})
	}
	if len(disks) == 0 {
		return nil, errors.New("no readable local drives")
	}
	sortDisksSystemFirst(disks, systemDriveMount())
	return disks, nil
}

// readExternalDriveSet asks each fixed drive for its storage bus. USB and
// FireWire enclosures report DRIVE_FIXED, so the drive type alone would show an
// external SSD as internal. It runs on the full refresh only.
func readExternalDriveSet() (map[string]bool, error) {
	external := map[string]bool{}
	for _, root := range localDrives() {
		bus, err := driveBusType(strings.TrimSuffix(root, `\`))
		if err != nil {
			continue
		}
		switch bus {
		case busTypeUSB, busType1394, busTypeSD, busTypeMMC:
			external[root] = true
		}
	}
	return external, nil
}

func driveBusType(device string) (uint32, error) {
	path, err := windows.UTF16PtrFromString(`\\.\` + device)
	if err != nil {
		return 0, err
	}
	// Zero access rights are enough for a property query and need no admin.
	h, err := windows.CreateFile(path, 0, windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, 0, 0)
	if err != nil {
		return 0, err
	}
	defer windows.CloseHandle(h) //nolint:errcheck

	// STORAGE_PROPERTY_QUERY{StorageDeviceProperty, PropertyStandardQuery}.
	query := make([]byte, 12)
	out := make([]byte, 1024)
	var returned uint32
	if err := windows.DeviceIoControl(h, ioctlStorageQueryProperty, &query[0], uint32(len(query)), &out[0], uint32(len(out)), &returned, nil); err != nil {
		return 0, err
	}
	if returned < storageBusTypeOffset+4 {
		return 0, errors.New("short storage descriptor")
	}
	return *(*uint32)(unsafe.Pointer(&out[storageBusTypeOffset])), nil
}

func readDiskIO() (uint64, uint64, error) {
	counters, err := disk.IOCounters()
	if err != nil {
		return 0, 0, err
	}
	if len(counters) == 0 {
		return 0, 0, errors.New("no disk counters")
	}
	var read, write uint64
	for _, c := range counters {
		read += c.ReadBytes
		write += c.WriteBytes
	}
	return read, write, nil
}

// --- Network ---

const ifTypePropVirtual = 53 // Wintun, WireGuard and most user-mode VPNs.

func readNetCounters() (map[string]netCounter, error) {
	stats, err := net.IOCounters(true)
	if err != nil {
		return nil, err
	}
	counters := make(map[string]netCounter, len(stats))
	for _, s := range stats {
		counters[s.Name] = netCounter{rx: s.BytesRecv, tx: s.BytesSent}
	}
	return counters, nil
}

// readNetAdapters returns the operational, non-loopback adapters keyed by the
// same friendly names the counters use, and marks the one carrying the IPv4
// default route (lowest metric wins when several have a gateway).
func readNetAdapters() ([]netAdapter, error) {
	flags := uint32(windows.GAA_FLAG_INCLUDE_GATEWAYS | windows.GAA_FLAG_SKIP_ANYCAST |
		windows.GAA_FLAG_SKIP_MULTICAST | windows.GAA_FLAG_SKIP_DNS_SERVER)
	size := uint32(16 * 1024)
	var buf []byte
	for range 3 {
		buf = make([]byte, size)
		err := windows.GetAdaptersAddresses(windows.AF_UNSPEC, flags, 0, (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])), &size)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.ERROR_BUFFER_OVERFLOW) {
			return nil, err
		}
		buf = nil
	}
	if buf == nil {
		return nil, errors.New("adapter list kept growing")
	}

	var adapters []netAdapter
	bestMetric := ^uint32(0)
	defaultIdx := -1
	for a := (*windows.IpAdapterAddresses)(unsafe.Pointer(&buf[0])); a != nil; a = a.Next {
		if a.OperStatus != windows.IfOperStatusUp || a.IfType == windows.IF_TYPE_SOFTWARE_LOOPBACK {
			continue
		}
		adapter := netAdapter{
			Name:     windows.UTF16PtrToString(a.FriendlyName),
			IsTunnel: a.IfType == windows.IF_TYPE_TUNNEL || a.IfType == ifTypePropVirtual || a.IfType == windows.IF_TYPE_PPP,
		}
		for u := a.FirstUnicastAddress; u != nil; u = u.Next {
			if ip := u.Address.IP(); ip != nil && ip.To4() != nil && !ip.IsLoopback() && !ip.IsLinkLocalUnicast() {
				adapter.IP = ip.String()
				break
			}
		}
		hasGateway := false
		for g := a.FirstGatewayAddress; g != nil; g = g.Next {
			if ip := g.Address.IP(); ip != nil && ip.To4() != nil && !ip.IsUnspecified() {
				hasGateway = true
				break
			}
		}
		if hasGateway && a.Ipv4Metric < bestMetric {
			bestMetric = a.Ipv4Metric
			defaultIdx = len(adapters)
		}
		adapters = append(adapters, adapter)
	}
	if defaultIdx >= 0 {
		adapters[defaultIdx].IsDefault = true
	}
	return adapters, nil
}

const internetSettingsKey = `Software\Microsoft\Windows\CurrentVersion\Internet Settings`

func readSystemProxy() ProxyStatus {
	k, err := registry.OpenKey(registry.CURRENT_USER, internetSettingsKey, registry.QUERY_VALUE)
	if err != nil {
		return ProxyStatus{}
	}
	defer k.Close() //nolint:errcheck
	enabled, _, _ := k.GetIntegerValue("ProxyEnable")
	server, _, _ := k.GetStringValue("ProxyServer")
	pac, _, _ := k.GetStringValue("AutoConfigURL")
	return proxyFromInternetSettings(enabled == 1, server, pac)
}

// --- Processes ---

// readProcesses reads the whole process table in one NtQuerySystemInformation
// call: CPU times, private working set and image name, with no per-process
// handle, so protected processes are included without elevation.
func readProcesses() ([]procSample, error) {
	size := uint32(512 * 1024)
	var buf []byte
	for range 6 {
		buf = make([]byte, size)
		var needed uint32
		err := windows.NtQuerySystemInformation(windows.SystemProcessInformation, unsafe.Pointer(&buf[0]), size, &needed)
		if err == nil {
			break
		}
		if !errors.Is(err, windows.STATUS_INFO_LENGTH_MISMATCH) {
			return nil, err
		}
		size = max(needed+64*1024, size*2)
		buf = nil
	}
	if buf == nil {
		return nil, errors.New("process table kept growing")
	}

	var samples []procSample
	offset := uintptr(0)
	for {
		p := (*windows.SYSTEM_PROCESS_INFORMATION)(unsafe.Pointer(&buf[offset]))
		samples = append(samples, procSample{
			PID:         int(p.UniqueProcessID),
			PPID:        int(p.InheritedFromUniqueProcessID),
			Image:       p.ImageName.String(),
			CreateTime:  p.CreateTime,
			CPUTime:     p.UserTime + p.KernelTime,
			MemoryBytes: uint64(max(p.WorkingSetPrivateSize, 0)),
		})
		if p.NextEntryOffset == 0 {
			break
		}
		offset += uintptr(p.NextEntryOffset)
		if offset >= uintptr(len(buf)) {
			break
		}
	}
	return samples, nil
}

// --- Battery ---

type systemPowerStatus struct {
	ACLineStatus        byte
	BatteryFlag         byte
	BatteryLifePercent  byte
	SystemStatusFlag    byte
	BatteryLifeTime     uint32
	BatteryFullLifeTime uint32
}

var guidDeviceBattery = windows.GUID{Data1: 0x72631e54, Data2: 0x78a4, Data3: 0x11d0, Data4: [8]byte{0xbc, 0xf7, 0x00, 0xaa, 0x00, 0xb7, 0xb3, 0x2a}}

const (
	ioctlBatteryQueryTag         = 0x294040
	ioctlBatteryQueryInformation = 0x294044
	batteryCapacityRelative      = 0x40000000
)

type batteryQueryInformation struct {
	BatteryTag       uint32
	InformationLevel int32 // BatteryInformation = 0
	AtRate           int32
}

type batteryInformation struct {
	Capabilities        uint32
	Technology          byte
	Reserved            [3]byte
	Chemistry           [4]byte
	DesignedCapacity    uint32
	FullChargedCapacity uint32
	DefaultAlert1       uint32
	DefaultAlert2       uint32
	CriticalBias        uint32
	CycleCount          uint32
}

// readBatteries returns nothing on a machine without a system battery, which
// the Power card renders as "No battery" exactly as main does on a Mac mini.
func readBatteries() ([]BatteryStatus, error) {
	var sps systemPowerStatus
	if ok, _, err := procGetSystemPowerStatus.Call(uintptr(unsafe.Pointer(&sps))); ok == 0 {
		return nil, err
	}
	if sps.BatteryFlag == 255 || sps.BatteryFlag&128 != 0 || sps.BatteryLifePercent > 100 {
		return nil, nil
	}
	status := BatteryStatus{
		Percent:  float64(sps.BatteryLifePercent),
		Status:   windowsBatteryStatus(sps.ACLineStatus, sps.BatteryFlag, sps.BatteryLifePercent),
		TimeLeft: formatBatteryTimeLeft(sps.BatteryLifeTime),
	}
	if design, full, cycles, err := readBatteryHealth(); err == nil {
		status.Capacity = batteryHealthPercent(design, full)
		status.CycleCount = cycles
	}
	return []BatteryStatus{status}, nil
}

func readBatteryHealth() (design, full, cycles int, err error) {
	paths, err := windows.CM_Get_Device_Interface_List("", &guidDeviceBattery, windows.CM_GET_DEVICE_INTERFACE_LIST_PRESENT)
	if err != nil {
		return 0, 0, 0, err
	}
	return collectBatteryHealth(paths, readBatteryDeviceHealth)
}

func readBatteryDeviceHealth(device string) (batteryHealthSample, error) {
	path, err := windows.UTF16PtrFromString(device)
	if err != nil {
		return batteryHealthSample{}, err
	}
	h, err := windows.CreateFile(path, windows.GENERIC_READ|windows.GENERIC_WRITE,
		windows.FILE_SHARE_READ|windows.FILE_SHARE_WRITE, nil, windows.OPEN_EXISTING, windows.FILE_ATTRIBUTE_NORMAL, 0)
	if err != nil {
		return batteryHealthSample{}, err
	}
	defer windows.CloseHandle(h) //nolint:errcheck

	return queryBatteryDeviceHealth(
		func(tag, returned *uint32) error {
			var wait uint32
			return windows.DeviceIoControl(h, ioctlBatteryQueryTag,
				(*byte)(unsafe.Pointer(&wait)), uint32(unsafe.Sizeof(wait)),
				(*byte)(unsafe.Pointer(tag)), uint32(unsafe.Sizeof(*tag)), returned, nil)
		},
		func(tag uint32, info *batteryInformation, returned *uint32) error {
			query := batteryQueryInformation{BatteryTag: tag}
			return windows.DeviceIoControl(h, ioctlBatteryQueryInformation,
				(*byte)(unsafe.Pointer(&query)), uint32(unsafe.Sizeof(query)),
				(*byte)(unsafe.Pointer(info)), uint32(unsafe.Sizeof(*info)), returned, nil)
		},
	)
}

func queryBatteryDeviceHealth(queryTag func(*uint32, *uint32) error, queryInfo func(uint32, *batteryInformation, *uint32) error) (batteryHealthSample, error) {
	var tag, returned uint32
	err := queryTag(&tag, &returned)
	// Only QueryTag's documented no-battery result identifies an empty bay.
	// A later FILE_NOT_FOUND can mean hot replacement, so it remains unknown.
	if errors.Is(err, windows.ERROR_FILE_NOT_FOUND) && tag == 0 {
		return batteryHealthSample{}, nil
	}
	if err != nil {
		return batteryHealthSample{}, err
	}
	if returned != uint32(unsafe.Sizeof(tag)) || tag == 0 {
		return batteryHealthSample{}, errors.New("battery tag incomplete")
	}
	var info batteryInformation
	returned = 0
	if err := queryInfo(tag, &info, &returned); err != nil {
		return batteryHealthSample{}, err
	}
	if returned != uint32(unsafe.Sizeof(info)) {
		return batteryHealthSample{}, errors.New("battery information incomplete")
	}

	// A successfully queried peripheral battery is not a system power battery.
	if info.Capabilities&0x80000000 == 0 {
		return batteryHealthSample{}, nil
	}
	return batteryHealthSample{
		present: true, relative: info.Capabilities&batteryCapacityRelative != 0,
		design: int(info.DesignedCapacity), full: int(info.FullChargedCapacity), cycles: int(info.CycleCount),
	}, nil
}

// --- Hardware ---

func readHardware() HardwareInfo {
	var hw HardwareInfo
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\BIOS`, registry.QUERY_VALUE); err == nil {
		manufacturer, _, _ := k.GetStringValue("SystemManufacturer")
		product, _, _ := k.GetStringValue("SystemProductName")
		version, _, _ := k.GetStringValue("SystemVersion")
		_ = k.Close()
		hw.Model = windowsModelName(manufacturer, product, version)
	}
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `HARDWARE\DESCRIPTION\System\CentralProcessor\0`, registry.QUERY_VALUE); err == nil {
		name, _, _ := k.GetStringValue("ProcessorNameString")
		_ = k.Close()
		hw.CPUModel = cleanCPUName(name)
	}
	if k, err := registry.OpenKey(registry.LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, registry.QUERY_VALUE); err == nil {
		displayVersion, _, _ := k.GetStringValue("DisplayVersion")
		if displayVersion == "" {
			displayVersion, _, _ = k.GetStringValue("ReleaseId")
		}
		_ = k.Close()
		hw.OSVersion = windowsOSVersion(int(windows.RtlGetVersion().BuildNumber), displayVersion)
	}
	hw.RefreshRate = primaryRefreshRate()
	return hw
}

// devMode is DEVMODEW, 220 bytes; only the size and frequency are used.
type devMode struct {
	DeviceName       [32]uint16
	SpecVersion      uint16
	DriverVersion    uint16
	Size             uint16
	DriverExtra      uint16
	Fields           uint32
	Position         [16]byte
	Color            int16
	Duplex           int16
	YResolution      int16
	TTOption         int16
	Collate          int16
	FormName         [32]uint16
	LogPixels        uint16
	BitsPerPel       uint32
	PelsWidth        uint32
	PelsHeight       uint32
	DisplayFlags     uint32
	DisplayFrequency uint32
	ICMMethod        uint32
	ICMIntent        uint32
	MediaType        uint32
	DitherType       uint32
	Reserved1        uint32
	Reserved2        uint32
	PanningWidth     uint32
	PanningHeight    uint32
}

const enumCurrentSettings = 0xFFFFFFFF

func primaryRefreshRate() string {
	var dm devMode
	dm.Size = uint16(unsafe.Sizeof(dm))
	enumCurrent := uint32(enumCurrentSettings)
	if ok, _, _ := procEnumDisplaySettingsW.Call(0, uintptr(enumCurrent), uintptr(unsafe.Pointer(&dm))); ok == 0 {
		return ""
	}
	// 0 and 1 mean "hardware default", not a measured rate.
	if dm.DisplayFrequency <= 1 || dm.DisplayFrequency >= 500 {
		return ""
	}
	return fmt.Sprintf("%dHz", dm.DisplayFrequency)
}
