import AppKit
import Foundation
import OrePersistence
import OreProtocol

/// Richer scientist profiles for the workspace identities, built from the
/// Wikipedia summary API and cached on disk as a local corpus.
///
/// The catalog in `ResearchIdentity` stays the source of truth and the offline
/// fallback — one hand-written line per scientist. This actor layers a fetched
/// biography, portrait and link on top, so the empty state can genuinely
/// highlight the person the workspace is named for. Everything is best-effort:
/// no network, a 404, or a slow response all degrade back to the hardcoded
/// fact, and the UI never waits on this to render.
actor ScientistCorpus {
    static let shared = ScientistCorpus()

    struct Profile: Codable, Sendable {
        var slug: String
        /// The lead-section extract — a few sentences of real biography.
        var extract: String
        /// Wikipedia's one-line description, e.g. "Iranian mathematician".
        var descriptionLine: String?
        var pageURL: String?
        /// File name of the cached portrait inside the corpus directory.
        var imageFileName: String?
        var fetchedAt: Date
    }

    /// The corpus lives beside the rest of ORE's state, honouring `$ORE_HOME`.
    private nonisolated var corpusDirectory: URL {
        OreHome.directory.appendingPathComponent("scientists", isDirectory: true)
    }

    private let refreshInterval: TimeInterval = 30 * 24 * 60 * 60
    private var inFlight: [String: Task<Profile?, Never>] = [:]

    /// Slugs whose plain name is ambiguous or abbreviated on Wikipedia.
    private static let titleOverrides: [String: String] = [
        "cecilia-payne": "Cecilia Payne-Gaposchkin",
        "chandrasekhar": "Subrahmanyan Chandrasekhar",
        "luis-leloir": "Luis Federico Leloir",
        "ibn-al-haytham": "Ibn al-Haytham",
    ]

    func profile(for identity: ResearchIdentity) async -> Profile? {
        if let cached = cachedProfile(slug: identity.slug),
           Date().timeIntervalSince(cached.fetchedAt) < refreshInterval {
            return cached
        }
        if let task = inFlight[identity.slug] {
            return await task.value
        }
        let task = Task { [weak self] in
            await self?.fetchAndCache(identity: identity)
        }
        inFlight[identity.slug] = task
        let profile = await task.value
        inFlight[identity.slug] = nil
        // A failed refresh still returns yesterday's corpus entry.
        return profile ?? cachedProfile(slug: identity.slug)
    }

    /// URL of the cached portrait, for synchronous loading into an NSImage.
    nonisolated func imageURL(for profile: Profile) -> URL? {
        guard let imageFileName = profile.imageFileName else { return nil }
        let url = corpusDirectory.appendingPathComponent(imageFileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Cache

    private nonisolated func cachedProfile(slug: String) -> Profile? {
        let url = corpusDirectory.appendingPathComponent("\(slug).json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Profile.self, from: data)
    }

    private func store(_ profile: Profile) {
        do {
            try FileManager.default.createDirectory(
                at: corpusDirectory, withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(profile)
            try data.write(
                to: corpusDirectory.appendingPathComponent("\(profile.slug).json"),
                options: .atomic
            )
        } catch {
            // Cache misses just mean a refetch next launch.
        }
    }

    // MARK: - Wikipedia

    private struct Summary: Decodable {
        struct Thumbnail: Decodable { var source: String }
        struct ContentURLs: Decodable {
            struct Pages: Decodable { var page: String }
            var desktop: Pages?
        }
        var extract: String?
        var description: String?
        var thumbnail: Thumbnail?
        var contentUrls: ContentURLs?

        enum CodingKeys: String, CodingKey {
            case extract, description, thumbnail
            case contentUrls = "content_urls"
        }
    }

    private func fetchAndCache(identity: ResearchIdentity) async -> Profile? {
        let title = Self.titleOverrides[identity.slug] ?? identity.name
        let path = title.replacingOccurrences(of: " ", with: "_")
        guard let encoded = path.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ), let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)")
        else { return nil }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let summary = try? JSONDecoder().decode(Summary.self, from: data),
              let extract = summary.extract, !extract.isEmpty
        else { return nil }

        var imageFileName: String?
        if let thumbnail = summary.thumbnail, let imageURL = URL(string: thumbnail.source) {
            imageFileName = await downloadPortrait(from: imageURL, slug: identity.slug)
        }

        let profile = Profile(
            slug: identity.slug,
            extract: extract,
            descriptionLine: summary.description,
            pageURL: summary.contentUrls?.desktop?.page,
            imageFileName: imageFileName,
            fetchedAt: Date()
        )
        store(profile)
        return profile
    }

    private func downloadPortrait(from url: URL, slug: String) async -> String? {
        let request = URLRequest(url: url, timeoutInterval: 10)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              !data.isEmpty
        else { return nil }

        let fileName = "\(slug).jpg"
        do {
            try FileManager.default.createDirectory(
                at: corpusDirectory, withIntermediateDirectories: true
            )
            try data.write(
                to: corpusDirectory.appendingPathComponent(fileName), options: .atomic
            )
            return fileName
        } catch {
            return nil
        }
    }
}
