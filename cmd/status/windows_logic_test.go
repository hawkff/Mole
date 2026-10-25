package main

import (
	"errors"
	"math"
	"strings"
	"testing"
	"time"
)

func TestWindowsModelName(t *testing.T) {
	tests := []struct {
		manufacturer, product, version, want string
	}{
		{"Parallels International GmbH.", "Parallels ARM Virtual Machine", "None", "Parallels ARM Virtual Machine"},
		{"Dell Inc.", "XPS 13 9310", "", "XPS 13 9310"},
		{"LENOVO", "20XW0055US", "ThinkPad X1 Carbon Gen 9", "ThinkPad X1 Carbon Gen 9"},
		{"LENOVO", "20XW0055US", "", "20XW0055US"},
		{"System manufacturer", "System Product Name", "System Version", ""},
		{"ASUS", "To Be Filled By O.E.M.", "", ""},
	}
	for _, tt := range tests {
		if got := windowsModelName(tt.manufacturer, tt.product, tt.version); got != tt.want {
			t.Errorf("windowsModelName(%q, %q, %q) = %q, want %q", tt.manufacturer, tt.product, tt.version, got, tt.want)
		}
	}
}

func TestCleanCPUName(t *testing.T) {
	tests := map[string]string{
		"Intel(R) Core(TM) i7-1165G7 @ 2.80GHz":                        "Intel Core i7-1165G7",
		"AMD Ryzen 7 5800X 8-Core Processor":                           "AMD Ryzen 7 5800X",
		"  Intel(R) Xeon(R) CPU E5-2680 v4 @ 2.40GHz  ":                "Intel Xeon CPU E5-2680 v4",
		"Snapdragon(R) X Elite - X1E78100 - Qualcomm(R) Oryon(TM) CPU": "Snapdragon X Elite - X1E78100 - Qualcomm Oryon",
		"Apple Silicon": "Apple Silicon",
	}
	for in, want := range tests {
		if got := cleanCPUName(in); got != want {
			t.Errorf("cleanCPUName(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestWindowsOSVersionUsesBuildForMajorVersion(t *testing.T) {
	tests := []struct {
		build   int
		display string
		want    string
	}{
		{26200, "25H2", "Windows 11 25H2"},
		{22000, "", "Windows 11"},
		{19045, "22H2", "Windows 10 22H2"},
		{0, "22H2", ""},
	}
	for _, tt := range tests {
		if got := windowsOSVersion(tt.build, tt.display); got != tt.want {
			t.Errorf("windowsOSVersion(%d, %q) = %q, want %q", tt.build, tt.display, got, tt.want)
		}
	}
}

func TestWindowsBatteryStatusMatchesPmsetWords(t *testing.T) {
	tests := []struct {
		ac, flag, percent byte
		want              string
	}{
		{1, 8, 60, "charging"},
		{1, 0, 100, "charged"},
		{1, 0, 80, "AC"},
		{0, 0, 80, "discharging"},
		{255, 0, 80, "Unknown"},
	}
	for _, tt := range tests {
		got := windowsBatteryStatus(tt.ac, tt.flag, tt.percent)
		if got != tt.want {
			t.Errorf("windowsBatteryStatus(%d, %d, %d) = %q, want %q", tt.ac, tt.flag, tt.percent, got, tt.want)
		}
	}
	// The words must keep main's AC detection working.
	for _, status := range []string{"charging", "charged", "AC"} {
		if !isPoweredByAC(strings.ToLower(status)) {
			t.Errorf("isPoweredByAC(%q) = false, want true", status)
		}
	}
	if isPoweredByAC("discharging") {
		t.Error("discharging must not read as AC power")
	}
}

func TestFormatBatteryTimeLeft(t *testing.T) {
	if got := formatBatteryTimeLeft(math.MaxUint32); got != "" {
		t.Errorf("unknown estimate = %q, want empty", got)
	}
	if got := formatBatteryTimeLeft(0); got != "" {
		t.Errorf("zero estimate = %q, want empty", got)
	}
	if got := formatBatteryTimeLeft(3*3600 + 45*60 + 30); got != "3:45" {
		t.Errorf("formatBatteryTimeLeft = %q, want 3:45", got)
	}
}

func TestBatteryHealthPercent(t *testing.T) {
	tests := []struct{ design, full, want int }{
		{50000, 45000, 90},
		{50000, 52000, 100},
		{0, 45000, 0},
		{50000, 0, 0},
	}
	for _, tt := range tests {
		if got := batteryHealthPercent(tt.design, tt.full); got != tt.want {
			t.Errorf("batteryHealthPercent(%d, %d) = %d, want %d", tt.design, tt.full, got, tt.want)
		}
	}
}

func TestRenderBatteryCardWithoutBatteryAfterProbe(t *testing.T) {
	card := renderBatteryCard(nil, true)
	if got := stripANSI(strings.Join(card.lines, "\n")); got != "No battery" {
		t.Fatalf("desktop Power card = %q, want main's No battery line", got)
	}
}

func TestDrivesSortSystemFirstAndRootDiskFollowsIt(t *testing.T) {
	disks := []DiskStatus{{Mount: `D:\`}, {Mount: `C:\`}, {Mount: `E:\`}}
	sortDisksSystemFirst(disks, normalizeDriveMount("c:"))
	if disks[0].Mount != `C:\` || disks[1].Mount != `D:\` {
		t.Fatalf("system drive must come first, got %+v", disks)
	}
	if got := normalizeDriveMount(`d:\`); got != `D:\` {
		t.Fatalf("normalizeDriveMount = %q", got)
	}
}

func TestProxyFromInternetSettings(t *testing.T) {
	tests := []struct {
		name        string
		enabled     bool
		server, pac string
		wantType    string
		wantHost    string
		wantEnabled bool
	}{
		{"single server", true, "10.211.55.2:7890", "", "HTTP", "10.211.55.2:7890", true},
		{"per protocol prefers socks", true, "http=h:1;https=h:2;socks=s:3", "", "SOCKS", "s:3", true},
		{"per protocol https", true, "http=h:1;https=h:2", "", "HTTPS", "h:2", true},
		{"disabled server falls to pac", false, "h:1", "http://wpad.local/proxy.pac", "PAC", "wpad.local", true},
		{"nothing", false, "", "", "", "", false},
	}
	for _, tt := range tests {
		got := proxyFromInternetSettings(tt.enabled, tt.server, tt.pac)
		if got.Enabled != tt.wantEnabled || got.Type != tt.wantType || got.Host != tt.wantHost {
			t.Errorf("%s: got %+v", tt.name, got)
		}
	}
}

func TestProcessInfoFromSamplesUsesOneCPUScale(t *testing.T) {
	prev := map[procKey]int64{
		{pid: 10, createTime: 1}: 0,
		{pid: 11, createTime: 1}: 0,
		{pid: 12, createTime: 5}: 0, // Same PID as the sample below, other creation time.
	}
	samples := []procSample{
		{PID: 0, Image: "", CPUTime: 40_000_000},                                                 // Idle
		{PID: 10, CreateTime: 1, Image: "chrome.exe", CPUTime: 15_000_000, MemoryBytes: 1 << 30}, // 1.5s in 1s
		{PID: 11, CreateTime: 1, Image: "big.EXE", CPUTime: 90_000_000},                          // capped at 4 CPUs
		{PID: 12, CreateTime: 9, Image: "reused.exe", CPUTime: 5_000_000},                        // PID reuse: no window
		{PID: 4, CreateTime: 1, Image: "", CPUTime: 0},
	}
	procs := processInfoFromSamples(samples, prev, time.Second, 4, 4<<30)
	byPID := map[int]ProcessInfo{}
	for _, p := range procs {
		byPID[p.PID] = p
	}
	if _, ok := byPID[0]; ok {
		t.Fatal("the Idle process must not be listed")
	}
	if p := byPID[10]; math.Abs(p.CPU-150) > 0.01 || p.Name != "chrome" || math.Abs(p.Memory-25) > 0.01 {
		t.Fatalf("chrome = %+v, want 150%% CPU, name chrome, 25%% memory", p)
	}
	if p := byPID[11]; p.CPU != 400 || p.Name != "big" {
		t.Fatalf("big = %+v, want CPU capped at 400%%", p)
	}
	if p := byPID[12]; p.CPU != 0 {
		t.Fatalf("a reused PID must not inherit the old process's CPU time: %+v", p)
	}
	if p := byPID[4]; p.Name != "System" {
		t.Fatalf("PID 4 = %+v, want System", p)
	}
}

func TestCollectNetworkListsRoutedTunnelOnlyAndShowsDefaultIP(t *testing.T) {
	stubPlatform(t)
	c := NewCollector(ProcessWatchOptions{})
	counters := map[string]netCounter{
		"Ethernet":  {rx: 0, tx: 0},
		"Wi-Fi":     {rx: 0, tx: 0},
		"WireGuard": {rx: 0, tx: 0},
	}
	readNetCountersFn = func() (map[string]netCounter, error) { return counters, nil }
	adapters := map[string]netAdapter{
		"Ethernet":  {Name: "Ethernet", IP: "10.0.0.2", IsDefault: true},
		"Wi-Fi":     {Name: "Wi-Fi", IP: "192.168.1.5"},
		"WireGuard": {Name: "WireGuard", IP: "10.8.0.2", IsTunnel: true},
	}
	start := time.Now()
	c.lastNetAt = time.Time{}
	c.collectNetwork(start, adapters)
	counters = map[string]netCounter{
		"Ethernet":  {rx: 2 << 20, tx: 1 << 20},
		"Wi-Fi":     {rx: 0, tx: 0},
		"WireGuard": {rx: 9 << 20, tx: 9 << 20},
	}
	stats := c.collectNetwork(start.Add(time.Second), adapters)
	for _, n := range stats {
		if n.Name == "WireGuard" {
			t.Fatal("a tunnel without the default route must not be listed")
		}
	}
	card := stripANSI(strings.Join(renderNetworkCard(stats, NetworkHistory{}, ProxyStatus{}, 40).lines, "\n"))
	if !strings.Contains(card, "10.0.0.2") || strings.Contains(card, "192.168.1.5") {
		t.Fatalf("network card should show the default-route IP only, got %q", card)
	}
	if !strings.Contains(card, "2.0 MB/s") {
		t.Fatalf("network card should show the Ethernet download rate, got %q", card)
	}
}

func TestCollectProxyLabelsRoutedTunnelAsTunnel(t *testing.T) {
	stubPlatform(t)
	for _, key := range []string{"https_proxy", "HTTPS_PROXY", "http_proxy", "HTTP_PROXY", "all_proxy", "ALL_PROXY"} {
		t.Setenv(key, "")
	}
	got := collectProxy(map[string]netAdapter{"WireGuard": {Name: "WireGuard", IsDefault: true, IsTunnel: true}})
	if !got.Enabled || !got.IsTunnel {
		t.Fatalf("routed tunnel = %+v, want a tunnel reading", got)
	}
	card := stripANSI(strings.Join(renderNetworkCard([]NetworkStatus{{Name: "x"}}, NetworkHistory{}, got, 40).lines, "\n"))
	if !strings.Contains(card, "Tunnel") || strings.Contains(card, "Proxy") {
		t.Fatalf("a tunnel must read as Tunnel, never Proxy: %q", card)
	}
}

func TestCollectorMarksCachedProcessesStaleOnFastSnapshot(t *testing.T) {
	stubPlatform(t)
	c := NewCollector(ProcessWatchOptions{})
	full, err := c.Collect()
	if err != nil {
		t.Fatalf("Collect() error = %v", err)
	}
	if full.ProcessStale == nil || *full.ProcessStale || len(full.TopProcesses) != 1 {
		t.Fatalf("full collection should carry a fresh process sample: %+v", full)
	}
	if full.Hardware.Model != "Test PC" || full.Hardware.TotalRAM != "16.0 GB" || full.Hardware.DiskSize != "100.0 GB" {
		t.Fatalf("hardware enrichment missing: %+v", full.Hardware)
	}
	fast, err := c.CollectFast()
	if err != nil {
		t.Fatalf("CollectFast() error = %v", err)
	}
	if fast.ProcessStale == nil || !*fast.ProcessStale {
		t.Fatalf("fast snapshot must mark reused process rows stale: %+v", fast.ProcessStale)
	}
	if fast.Hardware.Model != "Test PC" {
		t.Fatalf("fast snapshot lost cached hardware: %+v", fast.Hardware)
	}
}

func TestFormatCPUCoresLine(t *testing.T) {
	if got := formatCPUCoresLine(CPUStatus{CoreCount: 8, LogicalCPU: 16}); got != "Count  8 cores, 16 threads" {
		t.Errorf("SMT line = %q", got)
	}
	if got := formatCPUCoresLine(CPUStatus{CoreCount: 4, LogicalCPU: 4}); got != "Count  4 cores" {
		t.Errorf("no-SMT line = %q", got)
	}
	if got := formatCPUCoresLine(CPUStatus{}); got != "" {
		t.Errorf("unknown counts should hide the line, got %q", got)
	}
}

func TestBatteryHealthUsesEveryPresentPack(t *testing.T) {
	samples := map[string]batteryHealthSample{
		"empty":  {},
		"first":  {present: true, design: 40000, full: 30000, cycles: 40},
		"second": {present: true, design: 60000, full: 30000, cycles: 100},
	}
	read := func(path string) (batteryHealthSample, error) { return samples[path], nil }
	design, full, cycles, err := collectBatteryHealth([]string{"empty", "first", "second"}, read)
	if err != nil || design != 100000 || full != 60000 || cycles != 100 {
		t.Fatalf("combined=%d/%d cycles=%d err=%v", full, design, cycles, err)
	}
	samples["second"] = batteryHealthSample{present: true, design: 60000, full: 30000}
	design, full, cycles, err = collectBatteryHealth([]string{"first", "second"}, read)
	if err != nil || design != 100000 || full != 60000 || cycles != 0 {
		t.Fatal("unknown pack cycles reported as complete")
	}
	for _, bad := range []batteryHealthSample{
		{present: true, relative: true, design: 100, full: 80, cycles: 230},
		{present: true, design: 60000, cycles: 230},
	} {
		samples["second"] = bad
		for _, paths := range [][]string{{"second"}, {"first", "second"}} {
			design, full, cycles, err := collectBatteryHealth(paths, read)
			if err != nil || design != 0 || full != 0 || cycles != 230 {
				t.Fatalf("independent cycles lost: %d/%d cycles=%d err=%v", full, design, cycles, err)
			}
			card := renderBatteryCard([]BatteryStatus{{Percent: 50, Capacity: batteryHealthPercent(design, full), CycleCount: cycles, Status: "Discharging"}}, true)
			rendered := strings.Join(card.lines, "\n")
			if strings.Contains(rendered, "Healthy") || !strings.Contains(rendered, "230 cycles") {
				t.Fatalf("unknown aggregate capacity lost its meaning: %q", rendered)
			}
		}
	}
	if _, _, _, err := collectBatteryHealth([]string{"empty"}, read); err == nil {
		t.Fatal("empty bay accepted")
	}
	if _, _, _, err := collectBatteryHealth([]string{"first", "unknown"}, func(path string) (batteryHealthSample, error) {
		if path == "unknown" {
			return batteryHealthSample{}, errors.New("unreadable")
		}
		return samples[path], nil
	}); err == nil {
		t.Fatal("unreadable pack accepted")
	}
}
