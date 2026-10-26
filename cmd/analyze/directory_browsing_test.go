package main

import (
	"context"
	"fmt"
	"github.com/charmbracelet/x/ansi"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestLiveDirectoryListingKeepsEveryChild(t *testing.T) {
	root := t.TempDir()
	const count = 36
	for i := 0; i < count; i++ {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("item-%02d", i)), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	m := newModel(root, false)
	start := m.scanCmd(root)().(liveScanStartMsg)
	defer start.cancel()
	if len(start.entries) != count {
		t.Fatalf("initial rows=%d", len(start.entries))
	}
	next, _ := m.Update(start)
	m = next.(model)
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for m.scanning {
		select {
		case msg, ok := <-start.events:
			if !ok {
				t.Fatal("scan closed before completion")
			}
			next, _ = m.Update(msg)
			m = next.(model)
		case <-deadline.C:
			t.Fatal("scan did not finish")
		}
	}
	if len(m.entries) != count || len(m.cache[root].Entries) != count {
		t.Fatalf("completed listing lost children: view=%d cache=%d want=%d", len(m.entries), len(m.cache[root].Entries), count)
	}
	m.entryFilter = "item-35"
	m.applyEntryFilter()
	if len(m.entries) != 1 || m.entries[0].Path != filepath.Join(root, "item-35") {
		t.Fatalf("late child is not filterable: %+v", m.entries)
	}
}

func TestDirectoryRowsStayAlignedBeyondTwoDigitIndexes(t *testing.T) {
	m := model{path: "/fixture", width: 120, height: 8, selected: -1, totalSize: 10000}
	for i := range 10000 {
		name := fmt.Sprintf("entry-%05d", i)
		m.entries = append(m.entries, dirEntry{Name: name, Path: "/fixture/" + name, Size: 1})
	}
	for _, withHints := range []bool{false, true} {
		if withHints {
			for i := range m.entries {
				m.entries[i].LastAccess = time.Now().Add(-120 * 24 * time.Hour)
			}
		}
		for _, width := range []int{80, 120, 140} {
			m.width = width
			short := m
			short.entries = m.entries[:2]
			short.offset = 0
			rowWidth := ansi.StringWidth(rowContaining(ansi.Strip(short.View()), short.entries[0].Name))
			for _, offset := range []int{98, 998, 9998} {
				m.offset = offset
				view := ansi.Strip(m.View())
				first := rowContaining(view, m.entries[offset].Name)
				second := rowContaining(view, m.entries[offset+1].Name)
				firstPrefix, _, firstOK := strings.Cut(first, "  |  ")
				secondPrefix, _, secondOK := strings.Cut(second, "  |  ")
				if !firstOK || !secondOK || ansi.StringWidth(firstPrefix) != ansi.StringWidth(secondPrefix) {
					t.Fatalf("row numbers shifted the columns at %d:\n%s\n%s", offset+1, first, second)
				}
				if ansi.StringWidth(first) > rowWidth || ansi.StringWidth(second) > rowWidth {
					t.Fatalf("row numbers widened the rows at %d:\n%s\n%s", offset+1, first, second)
				}
			}
		}
	}
}

func TestCompletedListingKeepsSelectedPathInViewport(t *testing.T) {
	m := liveUpdateFixture(80)
	m.scanning = false
	m.autoSortLiveEntries = false
	for i := range m.entriesAll {
		m.entriesAll[i].Size = 1
	}
	m.selected, m.offset = 79, 75
	selected := m.selectedEntryPath()
	result := scanResult{Entries: append([]dirEntry(nil), m.entriesAll...), TotalSize: 80}
	result.Entries[79].Size = 100
	sortDirEntriesBySize(result.Entries)
	m.finishLiveScan(result)
	if m.selectedEntryPath() != selected || m.offset != 0 {
		t.Fatalf("refresh hid the selected path: selected=%s offset=%d", m.selectedEntryPath(), m.offset)
	}
}

func TestWarmedDirectorySummaryRefreshesBeforeBrowsing(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	if err := os.Mkdir(child, 0700); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 36; i++ {
		if err := os.WriteFile(filepath.Join(child, fmt.Sprintf("item-%02d", i)), []byte("x"), 0600); err != nil {
			t.Fatal(err)
		}
	}
	complete := func(m model) model {
		t.Helper()
		start := m.scanCmd(m.path)().(liveScanStartMsg)
		defer start.cancel()
		next, _ := m.Update(start)
		m = next.(model)
		deadline := time.NewTimer(5 * time.Second)
		defer deadline.Stop()
		for m.scanning {
			select {
			case event, ok := <-start.events:
				if !ok {
					t.Fatal("scan ended before completion")
				}
				next, _ = m.Update(event)
				m = next.(model)
			case <-deadline.C:
				t.Fatal("scan did not finish")
			}
		}
		return m
	}
	m := complete(newModel(root, false))
	if cached := m.cache[child]; !cached.NeedsRefresh || len(cached.Entries) > maxEntries {
		t.Fatalf("recursive summary must stay bounded and refresh on entry: %+v", cached)
	}
	next, cmd := m.enterSelectedDir()
	m = next.(model)
	if m.path != child || !m.scanning || cmd == nil {
		t.Fatal("entry reused a partial summary as a complete listing")
	}
	// Replace the queued request to exercise pre-dispatch cancellation too.
	m = complete(m)
	if len(m.entries) != 36 {
		t.Fatalf("child listing kept only %d rows", len(m.entries))
	}
	next, _ = m.goBack()
	m = next.(model)
	next, cmd = m.enterSelectedDir()
	m = next.(model)
	if m.path != child || m.scanning || cmd != nil || len(m.entries) != 36 {
		t.Fatalf("revisit lost completed listing: path=%s rows=%d scanning=%t", m.path, len(m.entries), m.scanning)
	}
	m.entryFilter = "item-35"
	m.applyEntryFilter()
	if len(m.entries) != 1 || m.selectedEntryPath() != filepath.Join(child, "item-35") {
		t.Fatal("cached last child is not selectable through the filter")
	}
}

// #1710: Analyze once stopped a directory walk three levels deep and skipped
// every folder whose name starts with a dot, so C:\ read 101 GB of 830 GB.
// Both sizing paths must count a file six levels down inside hidden folders:
// the folded walk (.venv) and the listing's own recursion (.config).
func TestDirectorySizesCountDeepAndHiddenDirs(t *testing.T) {
	root := t.TempDir()
	content := []byte("deep file")
	for _, hidden := range []string{".venv", ".config"} {
		deep := filepath.Join(root, hidden, "a", "b", "c", "d", "e")
		if err := os.MkdirAll(deep, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(deep, "deep.txt"), content, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.WriteFile(filepath.Join(root, "top.txt"), content, 0o644); err != nil {
		t.Fatal(err)
	}
	one := int64(len(content))

	size, err := calculateDirSizeFast(context.Background(), root, nil, nil, nil, nil, nil)
	if err != nil || size != 3*one {
		t.Fatalf("calculateDirSizeFast = %d, %v; want %d", size, err, 3*one)
	}

	result, err := scanPathConcurrent(context.Background(), root, nil, new(int64), new(int64), new(int64), nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalSize != 3*one {
		t.Fatalf("scan total = %d, want %d", result.TotalSize, 3*one)
	}
	for _, hidden := range []string{".venv", ".config"} {
		found := false
		for _, entry := range result.Entries {
			if entry.Name == hidden {
				found = true
				if !entry.IsDir || entry.Size != one {
					t.Fatalf("%s row = %+v, want a directory of %d bytes", hidden, entry, one)
				}
			}
		}
		if !found {
			t.Fatalf("%s is missing from the listing: %+v", hidden, result.Entries)
		}
	}
}
