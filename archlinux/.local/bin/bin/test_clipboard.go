package main

import (
	"fmt"
	"log"

	"clipboard-fzf/src/clipboard"
)

func main() {
	// Initialize clipboard manager
	clip, err := clipboard.NewManager()
	if err != nil {
		log.Fatalf("Failed to initialize clipboard manager: %v", err)
	}
	defer clip.Close()

	// Clear existing entries for testing
	fmt.Println("Clearing existing entries...")

	// Add some test entries
	testEntries := []string{
		"https://github.com/junegunn/fzf",
		"https://github.com/Slackadays/Clipboard/issues",
		"test content here",
		"another test line",
		"final test item",
	}

	fmt.Println("Adding test entries...")
	for _, entry := range testEntries {
		if err := clip.AddEntry(entry); err != nil {
			log.Printf("Failed to add entry '%s': %v", entry, err)
		} else {
			fmt.Printf("Added: %s\n", entry)
		}
	}

	// Retrieve entries
	fmt.Println("\nRetrieving entries...")
	entries, err := clip.GetEntries(100)
	if err != nil {
		log.Fatalf("Failed to retrieve entries: %v", err)
	}

	fmt.Printf("Found %d entries:\n", len(entries))
	for i, entry := range entries {
		fmt.Printf("%d. %s (size: %d, time: %s)\n", 
			i+1, entry.Content, entry.Size, entry.Timestamp.Format("2006-01-02 15:04:05"))
	}

	fmt.Println("\nClipboard manager test completed successfully!")
}
