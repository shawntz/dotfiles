package main

import (
	"fmt"
	"log"
	"os"

	"./src/clipboard"
	"./src/tui"
)

func main() {
	// Initialize clipboard manager
	clip, err := clipboard.NewManager()
	if err != nil {
		log.Fatalf("Failed to initialize clipboard manager: %v", err)
	}

	// Initialize terminal UI
	terminal, err := tui.NewTerminal(clip)
	if err != nil {
		log.Fatalf("Failed to initialize terminal UI: %v", err)
	}
	defer terminal.Close()

	// Run the main loop
	if err := terminal.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "Error: %v\n", err)
		os.Exit(1)
	}
}
