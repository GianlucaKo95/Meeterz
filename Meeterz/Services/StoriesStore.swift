import Foundation
import UIKit
import AVFoundation
import CoreLocation
import Observation
import Supabase

/// Stories: Foto oder Video (bis 15 s) an dem Ort, an dem es entstand – 24 Stunden für Freunde sichtbar.
/// Dateien im privaten Bucket "stories" unter "<user_id>/<story_id>.jpg|mp4"; wer sie sehen darf, regelt die Datenbank.
@MainActor @Observable
final class StoriesStore {
    struct Story: Decodable, Identifiable, Equatable {
        let id: UUID
        let userId: UUID
        let displayName: String
        let kind: String
        let mediaPath: String
        let lat: Double
        let lng: Double
        let placeName: String?
        let caption: String?
        let convoyKey: String?
        let createdAt: Date
        let expiresAt: Date
        var seen: Bool

        var isVideo: Bool { kind == "video" }
        var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lng) }
        var firstName: String { displayName.split(separator: " ").first.map(String.init) ?? displayName }

        enum CodingKeys: String, CodingKey {
            case id, kind, lat, lng, caption, seen
            case userId = "user_id"
            case displayName = "display_name"
            case mediaPath = "media_path"
            case placeName = "place_name"
            case convoyKey = "convoy_key"
            case createdAt = "created_at"
            case expiresAt = "expires_at"
        }
    }

    enum Media {
        case photo(UIImage)
        case video(URL)
    }

    private(set) var stories: [Story] = []
    private(set) var isPosting = false
    /// Gerade geöffnete Stories (Vollbild)
    var viewing: [Story]?

    @ObservationIgnored private var known = Set<UUID>()
    @ObservationIgnored private var loadedOnce = false
    @ObservationIgnored private var feed: RealtimeFeed?
    @ObservationIgnored private var me: UUID?
    private var client: SupabaseClient { Backend.client }
    private let bucket = "stories"

    func of(_ userId: UUID) -> [Story] { stories.filter { $0.userId == userId } }
    func hasUnseen(_ userId: UUID) -> Bool { stories.contains { $0.userId == userId && !$0.seen && $0.userId != me } }
    func hasStories(_ userId: UUID) -> Bool { stories.contains { $0.userId == userId } }

    // MARK: Laden

    func startListening(userId: UUID) async {
        guard feed == nil else { return }
        me = userId
        let feed = RealtimeFeed(topic: "stories-\(userId.uuidString.lowercased())", table: "stories") { [weak self] in
            await self?.refresh()
        }
        self.feed = feed
        await feed.start()
        await refresh()
        await removeExpired()
    }

    func stopListening() async {
        await feed?.stop()
        feed = nil
        stories = []
        known = []
        loadedOnce = false
        viewing = nil
        me = nil
    }

    func refresh() async {
        guard let rows: [Story] = try? await client.rpc("friend_stories").execute().value else { return }
        let fresh = rows.filter { !known.contains($0.id) && $0.userId != me }
        rows.forEach { known.insert($0.id) }
        stories = rows
        if loadedOnce {
            for s in fresh where Date().timeIntervalSince(s.createdAt) < 10 * 60 { announce(s) }
        }
        loadedOnce = true
    }

    /// Im Auto nur ein kurzer Hinweis, nie das Bild
    private func announce(_ s: Story) {
        let text = String(localized: "\(s.firstName) hat eine Story geteilt")
        if CarPlayController.shared.isConnected {
            let photo = AppModel.shared.avatars.image(for: s.userId)
            CarPlayController.shared.showNotice(title: [text], subtitle: s.placeName.map { [$0] },
                                                image: photo.map { AvatarRenderer.image(initials: "", color: .clear, faded: false, photo: $0) })
        } else {
            AppModel.shared.show(text, isError: false)
        }
    }

    // MARK: Ansehen

    /// Wer eine eigene Story gesehen hat (die Datenbank zeigt nur dem Besitzer die Aufrufe)
    struct Viewer: Decodable, Identifiable {
        let viewer: UUID
        let seenAt: Date
        var id: UUID { viewer }
        enum CodingKeys: String, CodingKey { case viewer; case seenAt = "seen_at" }
    }

    func viewers(of story: Story) async -> [Viewer] {
        (try? await client.from("story_views").select("viewer,seen_at")
            .eq("story_id", value: story.id).order("seen_at", ascending: false).execute().value) ?? []
    }

    var myId: UUID? { me }

    func open(_ userId: UUID) {
        let list = of(userId)
        if !list.isEmpty { viewing = list }
    }

    func markSeen(_ story: Story) {
        guard !story.seen, story.userId != me, let i = stories.firstIndex(where: { $0.id == story.id }) else { return }
        stories[i].seen = true
        Task {
            struct Row: Encodable { let story_id: UUID }
            _ = try? await client.from("story_views").upsert(Row(story_id: story.id), ignoreDuplicates: true).execute()
        }
    }

    /// Datei lokal (Cache) – Videos braucht AVPlayer als Datei
    func file(for story: Story) async -> URL? {
        let url = Self.cacheDirectory.appendingPathComponent((story.mediaPath as NSString).lastPathComponent)
        if FileManager.default.fileExists(atPath: url.path) { return url }
        guard let data = try? await client.storage.from(bucket).download(path: story.mediaPath) else { return nil }
        try? data.write(to: url)
        return url
    }

    // MARK: Teilen

    func post(_ media: Media, caption: String, placeName: String?, at coordinate: CLLocationCoordinate2D) async -> Bool {
        guard let me else { return false }
        isPosting = true
        defer { isPosting = false }
        let id = UUID()
        let video: Bool
        let data: Data?
        switch media {
        case .photo(let image):
            video = false
            data = Self.scaled(image, maxEdge: 1440).jpegData(compressionQuality: 0.8)
        case .video(let url):
            video = true
            data = await Self.compressed(url).flatMap { try? Data(contentsOf: $0) }
        }
        guard let data else {
            AppModel.shared.show(String(localized: "Story konnte nicht gespeichert werden."))
            return false
        }
        let path = "\(me.uuidString.lowercased())/\(id.uuidString.lowercased()).\(video ? "mp4" : "jpg")"
        struct Row: Encodable {
            let id: UUID; let kind: String; let media_path: String; let lat: Double; let lng: Double
            let place_name: String?; let caption: String?; let convoy_key: String?
        }
        let convoy = ConvoyFeed.shared.key
        do {
            _ = try await client.storage.from(bucket).upload(
                path, data: data, options: FileOptions(cacheControl: "86400", contentType: video ? "video/mp4" : "image/jpeg"))
            let text = caption.trimmingCharacters(in: .whitespacesAndNewlines)
            try await client.from("stories").insert(Row(
                id: id, kind: video ? "video" : "photo", media_path: path, lat: coordinate.latitude, lng: coordinate.longitude,
                place_name: placeName.map { String($0.prefix(120)) }, caption: text.isEmpty ? nil : String(text.prefix(140)),
                convoy_key: convoy)).execute()
            try? data.write(to: Self.cacheDirectory.appendingPathComponent((path as NSString).lastPathComponent))
            if convoy != nil { ConvoyFeed.shared.post(.story, storyId: id) }
            await refresh()
            return true
        } catch {
            Diag.log("Story nicht gespeichert: \(error.localizedDescription)")
            _ = try? await client.storage.from(bucket).remove(paths: [path])
            AppModel.shared.show(String(localized: "Story konnte nicht gespeichert werden."))
            return false
        }
    }

    func delete(_ story: Story) async {
        _ = try? await client.storage.from(bucket).remove(paths: [story.mediaPath])
        _ = try? await client.from("stories").delete().eq("id", value: story.id).execute()
        stories.removeAll { $0.id == story.id }
        if let list = viewing { viewing = list.filter { $0.id != story.id }.nilIfEmpty }
    }

    /// Eigene abgelaufene Stories samt Datei entfernen (nur die eigenen sind nach Ablauf noch lesbar)
    private func removeExpired() async {
        struct Old: Decodable { let id: UUID; let media_path: String }
        guard let old: [Old] = try? await client.from("stories").select("id,media_path")
            .lt("expires_at", value: ISO8601DateFormatter().string(from: Date())).execute().value, !old.isEmpty else { return }
        _ = try? await client.storage.from(bucket).remove(paths: old.map(\.media_path))
        _ = try? await client.from("stories").delete().in("id", values: old.map(\.id)).execute()
        // Cache: alles, was älter als 25 Stunden ist
        let dir = Self.cacheDirectory
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            if let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate,
               Date().timeIntervalSince(date) > 25 * 3600 { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: Medien

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("stories")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func scaled(_ image: UIImage, maxEdge: CGFloat) -> UIImage {
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    /// Video als MP4 in mittlerer Qualität (15 s ≈ 3–6 MB)
    private static func compressed(_ url: URL) async -> URL? {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: url), presetName: AVAssetExportPresetMediumQuality) else { return nil }
        do {
            try await export.export(to: out, as: .mp4)
            return out
        } catch {
            Diag.log("Video-Export fehlgeschlagen: \(error.localizedDescription)")
            return nil
        }
    }
}

private extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
