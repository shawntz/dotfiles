# Clipboard-fzf

A Go-based clipboard manager with an fzf-style terminal interface that provides the exact same look and feel as the popular fzf fuzzy finder.

## Features

- **Exact fzf Interface**: Uses the actual fzf TUI library for perfect visual replication
- **Clipboard History**: Encrypted storage of clipboard entries using SQLite
- **Fuzzy Search**: Real-time filtering of clipboard history
- **Secure**: AES-256-GCM encryption with PBKDF2 key derivation
- **Cross-platform**: Works on Linux, macOS, and Windows

## Why Go?

The original Python implementation had terminal wrapping issues and couldn't replicate fzf's exact interface. By using Go and the actual fzf TUI library, we get:

- **Perfect terminal handling**: No more text wrapping or alignment issues
- **Native performance**: Compiled binary with better performance
- **Professional UI**: The exact same interface as fzf
- **Reliable rendering**: Atomic interface updates prevent fragmentation

## Installation

### Prerequisites

- Go 1.21 or later
- SQLite3 development libraries

### Build from Source

```bash
git clone <repository-url>
cd clipboard-fzf
go build -o clipboard-fzf .
```

## Usage

```bash
# Run the clipboard manager
./clipboard-fzf
```

### Controls

- **Arrow Keys**: Navigate through entries
- **Type**: Filter entries in real-time
- **Enter**: Select and copy item to clipboard
- **ESC**: Exit

## Architecture

### Components

1. **Clipboard Manager** (`src/clipboard/`): Handles database operations and encryption
2. **Terminal UI** (`src/tui/`): fzf-style interface using the actual fzf TUI library
3. **Main Application**: Orchestrates the components

### Database Schema

```sql
CREATE TABLE clips (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    encrypted_content BLOB NOT NULL,
    timestamp INTEGER NOT NULL,
    size INTEGER NOT NULL
);
```

## Development

### Project Structure

```
clipboard-fzf/
├── main.go                 # Main application entry point
├── src/
│   ├── clipboard/         # Clipboard management and encryption
│   │   └── manager.go
│   └── tui/              # Terminal UI using fzf TUI
│       └── terminal.go
├── go.mod                 # Go module definition
└── README.md             # This file
```

### Dependencies

- `github.com/junegunn/fzf/src/tui`: fzf TUI library
- `github.com/mattn/go-sqlite3`: SQLite driver
- `golang.org/x/crypto/pbkdf2`: Password-based key derivation

## Future Enhancements

- [ ] Password prompt for encryption key
- [ ] Clipboard copying integration
- [ ] Configuration file support
- [ ] Preview window support
- [ ] Custom key bindings
- [ ] Export/import functionality

## License

MIT License - see LICENSE file for details.

## Acknowledgments

- [junegunn/fzf](https://github.com/junegunn/fzf) - The amazing fuzzy finder that inspired this project
- The Go community for excellent terminal UI libraries
