// pultik note — the scratch-note writer. Notes are the pultik panel's
// back-of-an-envelope rail (no state, no trigger, no vault — anything with a
// lifecycle belongs in `pultik todo`). They live in the app's notes.json;
// this command family is the external writer, and the app watches the file's
// directory so a note added here appears in the running panel.
package main

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// noteItem mirrors the app's SavedNote. Field order matches the app's
// sortedKeys output so both writers produce identical files.
type noteItem struct {
	CreatedAt string `json:"createdAt"`
	ID        string `json:"id"`
	Text      string `json:"text"`
}

// notesFile resolves the app's notes.json. Env override first, same contract
// as PULTIK_VAULT.
func notesFile() string {
	if v := os.Getenv("PULTIK_NOTES"); v != "" {
		return v
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, "Library", "Application Support", "Pultik", "notes.json")
}

func noteCmd(args []string) error {
	if len(args) == 0 {
		noteUsage()
		return fmt.Errorf("note needs a subcommand")
	}
	switch args[0] {
	case "add":
		return noteAdd(args[1:])
	case "list":
		return noteList(args[1:])
	case "rm":
		return noteRm(args[1:])
	case "--help", "-h", "help":
		noteUsage()
		return nil
	default:
		noteUsage()
		return fmt.Errorf("unknown note subcommand %q", args[0])
	}
}

func noteUsage() {
	fmt.Fprint(uiOut, `pultik note — scratch notes for the pultik panel rail

USAGE
  pultik note add <text...>       jot a note (shows in the panel immediately)
  pultik note add -               read the note text from stdin (multi-line)
  pultik note list [--json]       newest first
  pultik note rm <substring>      remove the newest note matching the text

Notes are deliberately dumber than todos: no state, no trigger, no vault.
Anything with a lifecycle belongs in pultik todo instead.
`)
}

func noteAdd(args []string) error {
	var text string
	if len(args) == 1 && args[0] == "-" {
		raw, err := io.ReadAll(os.Stdin)
		if err != nil {
			return fmt.Errorf("reading stdin: %w", err)
		}
		text = string(raw)
	} else {
		text = strings.Join(args, " ")
	}
	text = strings.TrimSpace(text)
	if text == "" {
		return fmt.Errorf("usage: pultik note add <text...> (or - for stdin)")
	}
	if err := withNotesLock(func() error {
		notes, err := readNotes()
		if err != nil {
			return err
		}
		notes = append(notes, noteItem{
			CreatedAt: time.Now().UTC().Format("2006-01-02T15:04:05Z"),
			ID:        newUUID(),
			Text:      text,
		})
		return writeNotes(notes)
	}); err != nil {
		return err
	}
	fmt.Fprintf(uiOut, "%s✓%s noted: %s\n", green, reset, oneLine(text, 72))
	return nil
}

func noteList(args []string) error {
	notes, err := readNotes()
	if err != nil {
		return err
	}
	// Newest first — recency is the only ordering that means anything.
	for i, j := 0, len(notes)-1; i < j; i, j = i+1, j-1 {
		notes[i], notes[j] = notes[j], notes[i]
	}
	if len(args) > 0 && args[0] == "--json" {
		out, _ := json.MarshalIndent(notes, "", "  ")
		fmt.Println(string(out))
		return nil
	}
	if len(notes) == 0 {
		fmt.Fprintf(uiOut, "no notes\n")
		return nil
	}
	for _, n := range notes {
		fmt.Fprintf(uiOut, "%s%4s%s  %s\n", dim, noteAge(n.CreatedAt), reset, oneLine(n.Text, 100))
	}
	return nil
}

func noteRm(args []string) error {
	needle := strings.ToLower(strings.TrimSpace(strings.Join(args, " ")))
	if needle == "" {
		return fmt.Errorf("usage: pultik note rm <substring>")
	}
	var removed *noteItem
	if err := withNotesLock(func() error {
		notes, err := readNotes()
		if err != nil {
			return err
		}
		// Newest-first match — the note you want gone is almost always the
		// one you just made.
		for i := len(notes) - 1; i >= 0; i-- {
			if strings.Contains(strings.ToLower(notes[i].Text), needle) {
				hit := notes[i]
				removed = &hit
				notes = append(notes[:i], notes[i+1:]...)
				return writeNotes(notes)
			}
		}
		return nil
	}); err != nil {
		return err
	}
	if removed == nil {
		return fmt.Errorf("no note matches %q", needle)
	}
	fmt.Fprintf(uiOut, "%s✓%s removed: %s\n", green, reset, oneLine(removed.Text, 72))
	return nil
}

// withNotesLock serializes the read-modify-write against the app: NoteStore
// takes flock on the same sidecar before its own RMW. Atomic rename alone
// prevents torn files, not lost updates.
func withNotesLock(body func() error) error {
	dir := filepath.Dir(notesFile())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	lock, err := os.OpenFile(notesFile()+".lock", os.O_CREATE|os.O_RDWR, 0o644)
	if err != nil {
		return body() // lock unavailable → still do the work
	}
	defer lock.Close()
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX); err == nil {
		defer syscall.Flock(int(lock.Fd()), syscall.LOCK_UN)
	}
	return body()
}

// readNotes tolerates a missing file (empty rail) but refuses to proceed on
// unreadable JSON — appending over a file we couldn't parse would destroy it.
func readNotes() ([]noteItem, error) {
	data, err := os.ReadFile(notesFile())
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	var notes []noteItem
	if err := json.Unmarshal(data, &notes); err != nil {
		return nil, fmt.Errorf("notes.json unreadable (%v) — fix or remove it first", err)
	}
	return notes, nil
}

// writeNotes is an atomic create-and-replace: the app watches the directory,
// and a rename is one filesystem event with no torn half-file to read.
func writeNotes(notes []noteItem) error {
	dir := filepath.Dir(notesFile())
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	out, err := json.MarshalIndent(notes, "", "  ")
	if err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".notes-*.json")
	if err != nil {
		return err
	}
	if _, err := tmp.Write(out); err != nil {
		tmp.Close()
		os.Remove(tmp.Name())
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(tmp.Name())
		return err
	}
	return os.Rename(tmp.Name(), notesFile())
}

// oneLine folds whitespace runs into single spaces and truncates — the same
// display contract as the app's SavedNote.oneLine.
func oneLine(text string, max int) string {
	s := strings.Join(strings.Fields(text), " ")
	if r := []rune(s); len(r) > max {
		return string(r[:max-1]) + "…"
	}
	return s
}

// noteAge mirrors the app's Date.shortAge chips (now/45s/6m/1h/2d).
func noteAge(created string) string {
	t, err := time.Parse(time.RFC3339, created)
	if err != nil {
		return "?"
	}
	d := time.Since(t)
	switch {
	case d < 10*time.Second:
		return "now"
	case d < time.Minute:
		return fmt.Sprintf("%ds", int(d.Seconds()))
	case d < time.Hour:
		return fmt.Sprintf("%dm", int(d.Minutes()))
	case d < 24*time.Hour:
		return fmt.Sprintf("%dh", int(d.Hours()))
	default:
		return fmt.Sprintf("%dd", int(d.Hours()/24))
	}
}

// newUUID is a random v4 UUID, uppercase like Swift's UUID().uuidString.
func newUUID() string {
	b := make([]byte, 16)
	if _, err := rand.Read(b); err != nil {
		panic(err) // crypto/rand failing means the machine is on fire
	}
	b[6] = (b[6] & 0x0f) | 0x40
	b[8] = (b[8] & 0x3f) | 0x80
	return strings.ToUpper(fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16]))
}
