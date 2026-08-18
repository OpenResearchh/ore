import CryptoKit
import Foundation

/// Remembers the audio of lines the neural voice has already spoken.
///
/// Narration is far more repetitive than it looks. "Done." "That failed."
/// "Reading three files." — the phraser draws from a fixed set of templates, so
/// across a working session the same few dozen strings are synthesized over and
/// over. Pocket TTS generates at roughly real time when the machine is busy
/// running agents, which is exactly when narration happens, so re-generating a
/// line already heard costs its whole duration in latency for an identical
/// waveform.
///
/// Keyed on the exact text, so nothing has to decide in advance which phrases
/// are "deterministic": a line repeats or it doesn't, and only the repeats pay
/// off. Lines carrying a file name or a summary simply never hit, which is
/// correct — they were never going to.
///
/// Two tiers. Memory answers within the same session with no I/O at all; disk
/// carries the common phrases across launches, so the first "Done." after a
/// cold start is instant too. The disk tier is a cache in the strict sense —
/// it lives under `~/Library/Caches`, and losing it costs one re-synthesis.
final class NarrationPhraseCache: @unchecked Sendable {
    /// Bumped whenever the voice model changes: cached waveforms belong to the
    /// model that produced them, and serving an old one after an upgrade would
    /// mean one voice for remembered lines and another for new ones.
    private static let formatVersion = "pocket-tts-1"

    /// Long lines are the ones least likely to repeat and the most expensive to
    /// keep, so the cache deliberately only holds short ones. 160 characters
    /// clears every template in `NarrationPhraser` with room to spare.
    private static let maxTextLength = 160

    /// Float32 mono at the model's sample rate: ~96 KB per second. 24 MB is
    /// about four minutes of speech, which covers the whole template set many
    /// times over while staying small next to the model itself.
    private let memoryBudget: Int
    private let diskBudget: Int

    private let lock = NSLock()
    private var memory: [String: [Float]] = [:]
    /// Keys oldest-use-first. Small enough (tens of entries) that an array
    /// scan beats the bookkeeping of anything cleverer.
    private var recency: [String] = []
    private var memoryBytes = 0

    private let directory: URL?

    init(memoryBudget: Int = 24 * 1_024 * 1_024, diskBudget: Int = 64 * 1_024 * 1_024) {
        self.memoryBudget = memoryBudget
        self.diskBudget = diskBudget
        self.directory = Self.makeDirectory()
        pruneDiskInBackground()
    }

    // MARK: - Lookup

    /// The synchronous tier, safe to consult on the main actor before deciding
    /// whether to synthesize at all.
    func cachedInMemory(_ text: String) -> [Float]? {
        guard let key = Self.key(for: text) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let samples = memory[key] else { return nil }
        touch(key)
        return samples
    }

    /// The disk tier. Reads a few hundred kilobytes, so callers run it off the
    /// main actor — the whole point is to be faster than synthesis, not to
    /// trade one stall for another.
    func cachedOnDisk(_ text: String) -> [Float]? {
        guard let key = Self.key(for: text), let url = fileURL(for: key) else { return nil }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        guard let samples = Self.decode(data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        // Reading counts as use: pruning drops the least recently touched, and
        // a phrase replayed every session must not age out behind one written
        // once and never heard again.
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: url.path
        )
        insertIntoMemory(key: key, samples: samples)
        return samples
    }

    // MARK: - Storing

    /// Whether a line is short enough to be worth remembering. Exposed so a
    /// caller can decide not to accumulate a waveform that `store` would only
    /// discard.
    static func isCacheable(_ text: String) -> Bool {
        key(for: text) != nil
    }

    /// Records a freshly synthesized line. Silently ignores anything too long
    /// to be worth keeping — the caller doesn't need to know the policy.
    func store(_ samples: [Float], for text: String) {
        guard !samples.isEmpty, let key = Self.key(for: text) else { return }
        // A single phrase must not evict everything else to fit.
        guard samples.count * MemoryLayout<Float>.size <= memoryBudget / 4 else { return }
        insertIntoMemory(key: key, samples: samples)
        writeToDiskInBackground(key: key, samples: samples)
    }

    // MARK: - Memory tier

    private func insertIntoMemory(key: String, samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        if let existing = memory[key] {
            memoryBytes -= existing.count * MemoryLayout<Float>.size
        }
        memory[key] = samples
        memoryBytes += samples.count * MemoryLayout<Float>.size
        touch(key)
        while memoryBytes > memoryBudget, let oldest = recency.first {
            recency.removeFirst()
            if let dropped = memory.removeValue(forKey: oldest) {
                memoryBytes -= dropped.count * MemoryLayout<Float>.size
            }
        }
    }

    /// Caller holds `lock`.
    private func touch(_ key: String) {
        if let index = recency.firstIndex(of: key) { recency.remove(at: index) }
        recency.append(key)
    }

    // MARK: - Disk tier

    private static func makeDirectory() -> URL? {
        guard let caches = FileManager.default.urls(
            for: .cachesDirectory, in: .userDomainMask
        ).first else { return nil }
        let bundle = Bundle.main.bundleIdentifier ?? "com.ore.OreMac"
        let url = caches
            .appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Narration", isDirectory: true)
            .appendingPathComponent(formatVersion, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true
            )
        } catch {
            return nil
        }
        return url
    }

    private func fileURL(for key: String) -> URL? {
        directory?.appendingPathComponent(key + ".pcm", isDirectory: false)
    }

    private func writeToDiskInBackground(key: String, samples: [Float]) {
        guard let url = fileURL(for: key) else { return }
        let data = Self.encode(samples)
        Task.detached(priority: .utility) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Trims the directory to `diskBudget`, oldest first. Runs once at startup
    /// rather than on every write: the cache grows by a few hundred kilobytes
    /// an hour, so anything more eager is pure I/O for no benefit.
    private func pruneDiskInBackground() {
        guard let directory else { return }
        let budget = diskBudget
        Task.detached(priority: .background) {
            let manager = FileManager.default
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            guard let entries = try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys
            ) else { return }
            let sized: [(url: URL, date: Date, size: Int)] = entries.compactMap { url in
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
                return (url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
            }
            var total = sized.reduce(0) { $0 + $1.size }
            guard total > budget else { return }
            for entry in sized.sorted(by: { $0.date < $1.date }) {
                guard total > budget else { break }
                try? manager.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }

    // MARK: - Encoding

    /// Raw little-endian Float32, the layout `AVAudioPCMBuffer` already wants.
    /// No container, no compression: the file is written once and read straight
    /// into a buffer, and a codec would put decode latency back into the path
    /// this exists to shorten.
    private static func encode(_ samples: [Float]) -> Data {
        samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private static func decode(_ data: Data) -> [Float]? {
        let stride = MemoryLayout<Float>.size
        guard !data.isEmpty, data.count % stride == 0 else { return nil }
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    /// Hashed rather than escaped: narration text contains slashes, quotes and
    /// file paths, and a fixed-width digest is both a valid filename and a
    /// dictionary key with no collisions worth worrying about.
    private static func key(for text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= maxTextLength else { return nil }
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
