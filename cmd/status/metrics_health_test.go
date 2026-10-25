package main

import (
	"strings"
	"testing"
)

func TestCalculateHealthScorePerfect(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 10},
		MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		[]DiskStatus{{UsedPercent: 30}},
		DiskIOStatus{ReadRate: 5, WriteRate: 5},
		nil, 0,
	)

	if score != 100 {
		t.Fatalf("expected perfect score 100, got %d", score)
	}
	if msg != "Excellent" {
		t.Fatalf("unexpected message %q", msg)
	}
}

func TestCalculateHealthScoreDetectsIssues(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 95},
		MemoryStatus{UsedPercent: 95, Pressure: "critical"},
		[]DiskStatus{{UsedPercent: 98}},
		DiskIOStatus{ReadRate: 120, WriteRate: 80},
		nil, 0,
	)

	if score >= 60 {
		t.Fatalf("expected heavy penalties bringing score down, got %d", score)
	}
	if msg == "Excellent" {
		t.Fatalf("expected message to include issues, got %q", msg)
	}
	if !strings.Contains(msg, "High CPU") {
		t.Fatalf("message should mention CPU issue: %q", msg)
	}
	if !strings.Contains(msg, "Disk Almost Full") {
		t.Fatalf("message should mention disk issue: %q", msg)
	}
}

func TestCalculateHealthScoreCapsFailingSMARTAt44(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 10},
		MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		[]DiskStatus{
			{UsedPercent: 30, SmartStatus: smartStatusVerified},
			{UsedPercent: 20, SmartStatus: smartStatusFailing},
		},
		DiskIOStatus{ReadRate: 5, WriteRate: 5},
		nil, 0,
	)

	if score != 44 {
		t.Fatalf("failing SMART score = %d, want 44", score)
	}
	if !strings.Contains(msg, "Disk SMART Failing") {
		t.Fatalf("failing SMART message = %q", msg)
	}
}

func TestCalculateHealthScoreDoesNotPenalizeUnavailableSMART(t *testing.T) {
	for _, status := range []string{smartStatusUnsupported, smartStatusUnknown} {
		score, msg := calculateHealthScore(
			CPUStatus{Usage: 10},
			MemoryStatus{UsedPercent: 20, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30, SmartStatus: status}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			nil, 0,
		)
		if score != 100 || msg != "Excellent" {
			t.Fatalf("SMART %q changed health to %d %q", status, score, msg)
		}
	}
}

func TestCalculateHealthScoreMonotonicInCPU(t *testing.T) {
	// Rising CPU usage must never improve (raise) the health score, including
	// across the high-usage threshold at 85%.
	prev := 101
	for usage := 40.0; usage <= 100.0; usage += 0.5 {
		score, _ := calculateHealthScore(
			CPUStatus{Usage: usage},
			MemoryStatus{UsedPercent: 20, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			nil, 0,
		)
		if score > prev {
			t.Fatalf("health score rose from %d to %d as CPU usage increased to %.1f%%", prev, score, usage)
		}
		prev = score
	}
}

func TestCalculateHealthScoreMonotonicInMemory(t *testing.T) {
	// Rising memory usage must never improve (raise) the health score, including
	// across the high-usage threshold at 88%.
	prev := 101
	for usage := 60.0; usage <= 100.0; usage += 0.5 {
		score, _ := calculateHealthScore(
			CPUStatus{Usage: 10},
			MemoryStatus{UsedPercent: usage, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			nil, 0,
		)
		if score > prev {
			t.Fatalf("health score rose from %d to %d as memory usage increased to %.1f%%", prev, score, usage)
		}
		prev = score
	}
}

func TestFormatUptime(t *testing.T) {
	if got := formatUptime(65); got != "1m" {
		t.Fatalf("expected 1m, got %s", got)
	}
	if got := formatUptime(3600 + 120); got != "1h 2m" {
		t.Fatalf("expected \"1h 2m\", got %s", got)
	}
	if got := formatUptime(86400*2 + 3600*3 + 60*5); got != "2d 3h" {
		t.Fatalf("expected \"2d 3h\", got %s", got)
	}
}

func TestCalculateHealthScoreEdgeCases(t *testing.T) {
	tests := []struct {
		name    string
		cpu     CPUStatus
		mem     MemoryStatus
		disks   []DiskStatus
		diskIO  DiskIOStatus
		wantMin int
		wantMax int
	}{
		{
			name:    "all metrics at normal threshold",
			cpu:     CPUStatus{Usage: 50.0},
			mem:     MemoryStatus{UsedPercent: 70.0},
			disks:   []DiskStatus{{UsedPercent: 80.0}},
			diskIO:  DiskIOStatus{ReadRate: 25.0, WriteRate: 25.0},
			wantMin: 95,
			wantMax: 100,
		},
		{
			name:    "memory pressure warning only",
			cpu:     CPUStatus{Usage: 10.0},
			mem:     MemoryStatus{UsedPercent: 40.0, Pressure: "warn"},
			disks:   []DiskStatus{{UsedPercent: 40.0}},
			diskIO:  DiskIOStatus{ReadRate: 5.0, WriteRate: 5.0},
			wantMin: 90,
			wantMax: 100,
		},
		{
			name:    "empty disks array",
			cpu:     CPUStatus{Usage: 10.0},
			mem:     MemoryStatus{UsedPercent: 30.0},
			disks:   []DiskStatus{},
			diskIO:  DiskIOStatus{ReadRate: 5.0, WriteRate: 5.0},
			wantMin: 95,
			wantMax: 100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			score, _ := calculateHealthScore(tt.cpu, tt.mem, tt.disks, tt.diskIO, nil, 0)
			if score < tt.wantMin || score > tt.wantMax {
				t.Errorf("calculateHealthScore() = %d, want range [%d, %d]", score, tt.wantMin, tt.wantMax)
			}
		})
	}
}

func TestBatteryHealthLabel(t *testing.T) {
	tests := []struct {
		name     string
		cycles   int
		capacity int
		label    string
		severity string
	}{
		{"new battery", 100, 98, "Healthy", "ok"},
		{"moderate cycles", 600, 92, "Healthy", "ok"},
		{"high cycles", 950, 85, "Service Soon", "danger"},
		{"low capacity", 200, 55, "Service Soon", "danger"},
		{"warn capacity", 200, 75, "Fair", "warn"},
		{"zero values", 0, 0, "", "unknown"},
		{"known cycles unknown capacity", 100, 0, "", "unknown"},
		{"unknown capacity high cycles", 950, 0, "Service Soon", "danger"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			label, severity := batteryHealthLabel(tt.cycles, tt.capacity)
			if label != tt.label {
				t.Errorf("batteryHealthLabel(%d, %d) label = %q, want %q", tt.cycles, tt.capacity, label, tt.label)
			}
			if severity != tt.severity {
				t.Errorf("batteryHealthLabel(%d, %d) severity = %q, want %q", tt.cycles, tt.capacity, severity, tt.severity)
			}
		})
	}
}

func TestUptimeSeverity(t *testing.T) {
	tests := []struct {
		name string
		secs uint64
		want string
	}{
		{"fresh restart", 3600, "ok"},
		{"6 days", 6 * 86400, "ok"},
		{"8 days", 8 * 86400, "warn"},
		{"15 days", 15 * 86400, "danger"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := uptimeSeverity(tt.secs)
			if got != tt.want {
				t.Errorf("uptimeSeverity(%d) = %q, want %q", tt.secs, got, tt.want)
			}
		})
	}
}

func TestHealthScoreBatteryPenalty(t *testing.T) {
	base := func(batts []BatteryStatus, uptime uint64) int {
		s, _ := calculateHealthScore(
			CPUStatus{Usage: 10}, MemoryStatus{UsedPercent: 20},
			[]DiskStatus{{UsedPercent: 30}}, DiskIOStatus{ReadRate: 5, WriteRate: 5},
			batts, uptime,
		)
		return s
	}

	perfect := base(nil, 0)
	withOldBattery := base([]BatteryStatus{{CycleCount: 950, Capacity: 75}}, 0)
	withLongUptime := base(nil, 15*86400)

	if withOldBattery >= perfect {
		t.Errorf("old battery should reduce score: got %d vs perfect %d", withOldBattery, perfect)
	}
	if withLongUptime >= perfect {
		t.Errorf("long uptime should reduce score: got %d vs perfect %d", withLongUptime, perfect)
	}
}

func TestFormatUptimeEdgeCases(t *testing.T) {
	tests := []struct {
		name string
		secs uint64
		want string
	}{
		{"zero seconds", 0, "0m"},
		{"59 seconds", 59, "0m"},
		{"one minute exact", 60, "1m"},
		{"59 minutes 59 seconds", 3599, "59m"},
		{"one hour exact", 3600, "1h 0m"},
		{"one day exact", 86400, "1d 0h"},
		{"one day one hour", 90000, "1d 1h"},
		{"multiple days no hours", 172800, "2d 0h"},
		{"large uptime", 31536000, "365d 0h"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatUptime(tt.secs)
			if got != tt.want {
				t.Errorf("formatUptime(%d) = %q, want %q", tt.secs, got, tt.want)
			}
		})
	}
}
