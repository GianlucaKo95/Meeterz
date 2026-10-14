import Foundation
import UIKit
import Observation
import Supabase

/// Profilbilder: eigenes Bild hochladen, Bilder angenommener Freunde laden und lokal zwischenspeichern.
/// Im privaten Bucket "avatars" unter "<user_id>/avatar.jpg"; die Rechte setzt die Storage-Policy (nur Freunde).
@MainActor @Observable
final class AvatarStore {
    /// Geladene Bilder je Nutzer (Freunde und ich selbst)
    private(set) var images: [UUID: UIImage] = [:]
    private(set) var isBusy = false

    @ObservationIgnored private var versions: [UUID: Int] = [:]
    @ObservationIgnored private var loading = Set<UUID>()

    private var client: SupabaseClient { Backend.client }
    private let bucket = "avatars"
    private let edge: CGFloat = 256

    func image(for id: UUID) -> UIImage? { images[id] }

    // MARK: Freunde synchronisieren

    /// Lädt neue oder geänderte Bilder, entfernt Bilder von Nutzern ohne Bild oder ohne Freundschaft.
    func sync(friends: [FriendRow], me: Profile?) async {
        var wanted: [UUID: Int] = [:]
        for f in friends where f.isAccepted && (f.avatarVersion ?? 0) > 0 { wanted[f.friendId] = f.avatarVersion! }
        if let me, (me.avatarVersion ?? 0) > 0 { wanted[me.id] = me.avatarVersion! }

        for id in images.keys where wanted[id] == nil { images[id] = nil; versions[id] = nil }
        for (id, version) in wanted where versions[id] != version {
            await load(id, version: version)
        }
    }

    private func load(_ id: UUID, version: Int) async {
        guard !loading.contains(id) else { return }
        loading.insert(id)
        defer { loading.remove(id) }

        if let cached = Self.readCache(id: id, version: version) {
            images[id] = cached
            versions[id] = version
            return
        }
        do {
            let data = try await client.storage.from(bucket).download(path: Self.path(for: id))
            guard let image = UIImage(data: data) else { return }
            Self.writeCache(data, id: id, version: version)
            images[id] = image
            versions[id] = version
        } catch {
            // Bild nicht abrufbar (z. B. keine Freundschaft mehr): Initialen bleiben
        }
    }

    // MARK: Eigenes Bild

    /// Schneidet mittig quadratisch zu, verkleinert auf 256 px und lädt hoch.
    func setMine(_ picked: UIImage, userId: UUID) async -> Int? {
        guard let data = square(picked).jpegData(compressionQuality: 0.8) else { return nil }
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.storage.from(bucket).upload(
                Self.path(for: userId), data: data,
                options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)
            )
            let version: Int = try await client.rpc("set_avatar_version").execute().value
            Self.writeCache(data, id: userId, version: version)
            if let image = UIImage(data: data) { images[userId] = image }
            versions[userId] = version
            return version
        } catch {
            AppModel.shared.show("Profilbild konnte nicht gespeichert werden.")
            return nil
        }
    }

    /// Entfernt das eigene Bild (Datei und Version).
    func removeMine(userId: UUID) async -> Bool {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await client.storage.from(bucket).remove(paths: [Self.path(for: userId)])
            let _: Int = try await client.rpc("set_avatar_version", params: ["remove": true]).execute().value
            images[userId] = nil
            versions[userId] = nil
            return true
        } catch {
            AppModel.shared.show("Profilbild konnte nicht entfernt werden.")
            return false
        }
    }

    /// Vor dem Löschen des Kontos: Datei aus dem Speicher entfernen
    func deleteFile(userId: UUID) async {
        _ = try? await client.storage.from(bucket).remove(paths: [Self.path(for: userId)])
    }

    func reset() {
        images = [:]
        versions = [:]
    }

    // MARK: Bild und Cache

    private func square(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let crop = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: edge, height: edge), format: format).image { _ in
            let scale = edge / side
            image.draw(in: CGRect(x: -crop.minX * scale, y: -crop.minY * scale,
                                  width: image.size.width * scale, height: image.size.height * scale))
        }
    }

    /// Kleinbuchstaben: Die Storage-Policy vergleicht mit auth.uid()::text
    private static func path(for id: UUID) -> String { "\(id.uuidString.lowercased())/avatar.jpg" }

    private static var cacheDirectory: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("avatars")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cacheURL(id: UUID, version: Int) -> URL {
        cacheDirectory.appendingPathComponent("\(id.uuidString.lowercased())-\(version).jpg")
    }

    private static func readCache(id: UUID, version: Int) -> UIImage? {
        UIImage(contentsOfFile: cacheURL(id: id, version: version).path)
    }

    private static func writeCache(_ data: Data, id: UUID, version: Int) {
        // ältere Versionen desselben Nutzers entfernen
        let prefix = id.uuidString.lowercased()
        if let files = try? FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path) {
            for file in files where file.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(file))
            }
        }
        try? data.write(to: cacheURL(id: id, version: version))
    }
}
