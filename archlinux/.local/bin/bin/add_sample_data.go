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

	// Add some sample entries
	sampleEntries := []string{
		"https://github.com/junegunn/fzf",
		"https://github.com/Slackadays/Clipboard",
		"Hello, this is a test clipboard entry",
		"Another test entry with some content",
		"Final test entry for demonstration",
		"https://www.google.com",
		"https://stackoverflow.com",
		"This is a longer entry that might wrap in the terminal",
		"Short entry",
		"Medium length entry here",
	}

	fmt.Println("Adding sample clipboard entries...")
	for _, entry := range sampleEntries {
		if err := clip.AddEntry(entry); err != nil {
			log.Printf("Failed to add entry '%s': %v", entry, err)
		} else {
			fmt.Printf("✓ Added: %s\n", entry)
		}
	}

	// Verify entries were added
	entries, err := clip.GetEntries(100)
	if err != nil {
		log.Fatalf("Failed to retrieve entries: %v", err)
	}

	fmt.Printf("\n✓ Successfully added %d entries to the test database\n", len(entries))
	fmt.Println("You can now run ./clipboard-fzf to see the interface!")
}
