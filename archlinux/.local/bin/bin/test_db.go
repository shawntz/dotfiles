package main

import (
	"fmt"
	"log"
	"os"

	"clipboard-fzf/src/clipboard"
)

func main() {
	fmt.Println("Testing clipboard database operations...")
	
	// Initialize clipboard manager
	clip, err := clipboard.NewManager()
	if err != nil {
		log.Fatalf("Failed to initialize clipboard manager: %v", err)
	}
	defer clip.Close()

	// Test adding an entry
	testContent := "test clipboard content for Go app"
	fmt.Printf("Adding test content: %s\n", testContent)
	
	if err := clip.AddEntry(testContent); err != nil {
		log.Fatalf("Failed to add entry: %v", err)
	}
	fmt.Println("✓ Entry added successfully")

	// Test retrieving entries
	entries, err := clip.GetEntries(100)
	if err != nil {
		log.Fatalf("Failed to retrieve entries: %v", err)
	}

	fmt.Printf("Found %d entries:\n", len(entries))
	for i, entry := range entries {
		fmt.Printf("%d. %s (size: %d, time: %s)\n", 
			i+1, entry.Content, entry.Size, entry.Timestamp.Format("2006-01-02 15:04:05"))
	}

	fmt.Println("\n✓ Database operations test completed successfully!")
}
