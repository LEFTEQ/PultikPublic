import Foundation
import Observation

/// A one-line scratch note.
///
/// Deliberately dumber than a todo: no state, no trigger, no server. This is the
/// back of an envelope — something you want in front of you for the next hour.
/// Anything with a lifecycle belongs in vitrinka todos instead.
struct SavedNote: Codable, Identifiable {
    var id: String
    var text: String
    var createdAt: Date

    /// The note as ONE line: newlines and runs of whitespace fold into single
    /// spaces so a pasted blob reads as prose when truncated. Taking line 1
    /// instead would show whatever fragment the paste happened to break on
    /// ("can you write me a \"testing"), which truncates mid-thought.
    var oneLine: String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Full-text match — the point of searching a pasted spec is finding a
    /// word buried on line 30, so this deliberately looks past the head.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        return text.lowercased().contains(q)
    }
}

/// Notes, stored beside settings.json and links.json.
@MainActor
@Observable
final class NoteStore {
    static let shared = NoteStore()

    private(set) var notes: [SavedNote] = []

    static let fileURL = Preferences.directory.appending(path: "notes.json")

    private var watcher: DispatchSourceFileSystemObject?
    private var reloadDebounce: Task<Void, Never>?

    private init() {
        load()
        startWatching()
    }

    /// Newest first. Links sort by use because you re-open a link; a note is
    /// read, not used, so recency is the only ordering that means anything.
    var ordered: [SavedNote] {
        notes.sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    func add(_ raw: String) -> SavedNote? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let note = SavedNote(id: UUID().uuidString, text: text, createdAt: Date())
        mutate { $0.append(note) }
        return note
    }

    /// Rewrite a note's text in place. `createdAt` is left alone: the age chip
    /// answers "when did I write this down", and a typo fix shouldn't reset it.
    /// Returns `false` when the edit is rejected (empty text, unknown id) so
    /// the caller can keep its editor open instead of dropping the draft.
    @discardableResult
    func update(id: String, text raw: String) -> Bool {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var found = false
        mutate { notes in
            guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
            found = true
            notes[index].text = text
        }
        return found
    }

    func remove(id: String) {
        mutate { $0.removeAll { $0.id == id } }
    }

    /// Fuzzy delete for `/rm-note <text>`.
    func remove(matching text: String) -> SavedNote? {
        let needle = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty,
              let hit = notes.first(where: { $0.text.lowercased().contains(needle) })
        else { return nil }
        remove(id: hit.id)
        return hit
    }

    // MARK: - Mutation (serialized against the CLI)

    /// Every mutation is a locked read-modify-write against the file, not the
    /// in-memory array: `pultik note add`/`rm` do their own RMW on the same
    /// notes.json, and atomic rename only prevents torn files, not lost
    /// updates. Under `flock` both writers see each other's latest state —
    /// the CLI (`tools/pultik/note.go`) takes the same lock.
    private func mutate(_ change: (inout [SavedNote]) -> Void) {
        withFileLock {
            load()
            change(&notes)
            save()
        }
    }

    /// `flock(2)` on a sidecar lock file — the data file itself can't be
    /// locked because both writers replace it by rename.
    private func withFileLock(_ body: () -> Void) {
        try? FileManager.default.createDirectory(
            at: Preferences.directory, withIntermediateDirectories: true
        )
        let lockPath = Self.fileURL.path + ".lock"
        let fd = Darwin.open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { body(); return }   // lock unavailable → still do the work
        defer { close(fd) }
        if flock(fd, LOCK_EX) != 0 {
            NSLog("pultik: notes.json.lock flock failed (%d) — writing unlocked", errno)
        }
        defer { flock(fd, LOCK_UN) }
        body()
    }

    // MARK: - Watching

    /// Dir-level watcher, like TodoStore's: `pultik note add` replaces
    /// notes.json atomically (rename), which kills a file-level watch's inode
    /// but always surfaces as a write on the containing directory. Settings
    /// and links saves trigger harmless extra reloads.
    private func startWatching() {
        guard watcher == nil else { return }
        let fd = Darwin.open(Preferences.directory.path, O_EVTONLY)
        guard fd >= 0 else {
            // Dir not created yet. An in-app save retries directly (it creates
            // the dir), but the dir can also appear from outside — a CLI
            // `pultik note add` — so keep retrying until the watch lands.
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                self?.startWatching()
            }
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
        // Catch up on anything written before resume() — on the retry path a
        // CLI add can create the dir AND the file inside the 5 s window, and
        // that write predates the watch.
        scheduleReload()
    }

    private func scheduleReload() {
        reloadDebounce?.cancel()
        reloadDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL) else { return }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            notes = try decoder.decode([SavedNote].self, from: data)
        } catch {
            NSLog("pultik: notes.json unreadable (%@) — leaving it in place",
                  error.localizedDescription)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: Preferences.directory, withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(notes).write(to: Self.fileURL, options: .atomic)
        } catch {
            NSLog("pultik: could not save notes.json — %@", error.localizedDescription)
        }
    }
}
