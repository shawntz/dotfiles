package clipboard

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"golang.org/x/crypto/pbkdf2"
)

// Entry represents a clipboard entry
type Entry struct {
	ID        int64
	Content   string
	Timestamp time.Time
	Size      int
}

// Manager handles clipboard operations
type Manager struct {
	db       *sql.DB
	dbPath   string
	key      []byte
	salt     []byte
}

// NewManager creates a new clipboard manager
func NewManager() (*Manager, error) {
	configDir := filepath.Join(os.Getenv("HOME"), ".config", "clipd")
	if err := os.MkdirAll(configDir, 0755); err != nil {
		return nil, fmt.Errorf("failed to create config directory: %v", err)
	}

	// Use the existing clips.db database
	dbPath := filepath.Join(configDir, "clips.db")
	saltPath := filepath.Join(configDir, ".salt")

	// Check if salt exists, create if not
	var salt []byte
	if _, err := os.Stat(saltPath); os.IsNotExist(err) {
		salt = make([]byte, 32)
		if _, err := rand.Read(salt); err != nil {
			return nil, fmt.Errorf("failed to generate salt: %v", err)
		}
		if err := os.WriteFile(saltPath, salt, 0600); err != nil {
			return nil, fmt.Errorf("failed to write salt: %v", err)
		}
	} else {
		saltData, err := os.ReadFile(saltPath)
		if err != nil {
			return nil, fmt.Errorf("failed to read salt: %v", err)
		}
		salt = saltData
	}

	// For now, use a simple key derivation
	// In production, you'd want to prompt for a password
	// Try to use the same key as the existing clipd application
	key := pbkdf2.Key([]byte("default-password"), salt, 100000, 32, sha256.New)

	db, err := sql.Open("sqlite3", dbPath)
	if err != nil {
		return nil, fmt.Errorf("failed to open database: %v", err)
	}

	if err := db.Ping(); err != nil {
		return nil, fmt.Errorf("failed to ping database: %v", err)
	}

	// Create tables if they don't exist
	if err := createTables(db); err != nil {
		return nil, fmt.Errorf("failed to create tables: %v", err)
	}

	return &Manager{
		db:     db,
		dbPath: dbPath,
		key:    key,
		salt:   salt,
	}, nil
}

// createTables creates the necessary database tables
func createTables(db *sql.DB) error {
	query := `
	CREATE TABLE IF NOT EXISTS clips (
		id INTEGER PRIMARY KEY AUTOINCREMENT,
		encrypted_content BLOB NOT NULL,
		timestamp INTEGER NOT NULL,
		size INTEGER NOT NULL
	);
	CREATE INDEX IF NOT EXISTS idx_timestamp ON clips(timestamp);
	`
	_, err := db.Exec(query)
	return err
}

// AddEntry adds a new clipboard entry
func (m *Manager) AddEntry(content string) error {
	encrypted, err := m.encrypt(content)
	if err != nil {
		return fmt.Errorf("failed to encrypt content: %v", err)
	}

	query := `INSERT INTO clips (encrypted_content, timestamp, size) VALUES (?, ?, ?)`
	_, err = m.db.Exec(query, encrypted, time.Now().Unix(), len(content))
	return err
}

// GetEntries retrieves clipboard entries, optionally filtered
func (m *Manager) GetEntries(limit int) ([]Entry, error) {
	query := `SELECT id, encrypted_content, timestamp, size FROM clips ORDER BY timestamp DESC LIMIT ?`
	rows, err := m.db.Query(query, limit)
	if err != nil {
		return nil, fmt.Errorf("failed to query entries: %v", err)
	}
	defer rows.Close()

	var entries []Entry
	for rows.Next() {
		var entry Entry
		var encryptedContent []byte
		var timestamp int64

		if err := rows.Scan(&entry.ID, &encryptedContent, &timestamp, &entry.Size); err != nil {
			continue // Skip invalid entries
		}

		content, err := m.decrypt(encryptedContent)
		if err != nil {
			continue // Skip entries we can't decrypt
		}

		entry.Content = content
		entry.Timestamp = time.Unix(timestamp, 0)
		entries = append(entries, entry)
	}

	return entries, nil
}

// encrypt encrypts content using AES-256-GCM
func (m *Manager) encrypt(content string) ([]byte, error) {
	block, err := aes.NewCipher(m.key)
	if err != nil {
		return nil, err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}

	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(rand.Reader, nonce); err != nil {
		return nil, err
	}

	ciphertext := gcm.Seal(nonce, nonce, []byte(content), nil)
	return ciphertext, nil
}

// decrypt decrypts content using AES-256-GCM
func (m *Manager) decrypt(encrypted []byte) (string, error) {
	block, err := aes.NewCipher(m.key)
	if err != nil {
		return "", err
	}

	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}

	nonceSize := gcm.NonceSize()
	if len(encrypted) < nonceSize {
		return "", fmt.Errorf("ciphertext too short")
	}

	nonce, ciphertext := encrypted[:nonceSize], encrypted[nonceSize:]
	plaintext, err := gcm.Open(nil, nonce, ciphertext, nil)
	if err != nil {
		return "", err
	}

	return string(plaintext), nil
}

// Close closes the database connection
func (m *Manager) Close() error {
	return m.db.Close()
}
