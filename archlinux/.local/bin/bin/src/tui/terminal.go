package tui

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"time"

	"clipboard-fzf/src/clipboard"
)

// Terminal represents the main terminal UI
type Terminal struct {
	clipboard *clipboard.Manager
	entries   []clipboard.Entry
	selected  int
	query     string
	lastClip  string
	ctx       context.Context
	cancel    context.CancelFunc
}

// NewTerminal creates a new terminal UI
func NewTerminal(clip *clipboard.Manager) (*Terminal, error) {
	// Load clipboard entries
	entries, err := clip.GetEntries(1000)
	if err != nil {
		return nil, fmt.Errorf("failed to load entries: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Terminal{
		clipboard: clip,
		entries:   entries,
		selected:  0,
		query:     "",
		lastClip:  "",
		ctx:       ctx,
		cancel:    cancel,
	}, nil
}

// Run starts the main terminal loop
func (t *Terminal) Run() error {
	fmt.Println("Clipboard-fzf - Clipboard Monitor")
	fmt.Println("=================================")
	fmt.Printf("Found %d existing clipboard entries\n\n", len(t.entries))

	// Start clipboard monitoring
	t.startClipboardMonitoring()

	fmt.Println("🔍 Monitoring clipboard for new content...")
	fmt.Println("📋 Copy something to see it appear here!")
	fmt.Println("")

	// Display existing entries
	if len(t.entries) > 0 {
		fmt.Println("Existing entries:")
		for i, entry := range t.entries {
			if i == t.selected {
				fmt.Printf("▌ %s\n", entry.Content)
			} else {
				fmt.Printf("  %s\n", entry.Content)
			}
		}
		fmt.Println("")
	}

	fmt.Println("Press Enter to exit...")
	fmt.Scanln()

	return nil
}

// Close closes the terminal
func (t *Terminal) Close() {
	t.cancel()
}

// startClipboardMonitoring starts monitoring the clipboard for changes
func (t *Terminal) startClipboardMonitoring() {
	go func() {
		ticker := time.NewTicker(2 * time.Second)
		defer ticker.Stop()
		
		for {
			select {
			case <-t.ctx.Done():
				return
			case <-ticker.C:
				currentClip := t.getClipboard()
				if currentClip != "" && currentClip != t.lastClip && len(strings.TrimSpace(currentClip)) > 0 {
					// New clipboard content detected
					if err := t.clipboard.AddEntry(currentClip); err != nil {
						fmt.Fprintf(os.Stderr, "Failed to store clipboard: %v\n", err)
					} else {
						t.lastClip = currentClip
						fmt.Printf("📋 New clipboard content captured: %s\n", currentClip)
						// Refresh entries list
						if newEntries, err := t.clipboard.GetEntries(1000); err == nil {
							t.entries = newEntries
						}
					}
				}
			}
		}
	}()
}

// getClipboard gets the current clipboard content using wl-paste
func (t *Terminal) getClipboard() string {
	cmd := exec.Command("wl-paste")
	output, err := cmd.Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(output))
}
