import SwiftUI
import AVKit
import CoreLocation
import UIKit

// MARK: - Aufnehmen

/// Kamera für Stories: Foto oder Video (höchstens 15 s), Rückkamera
struct StoryCamera: UIViewControllerRepresentable {
    let onPick: (StoriesStore.Media) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.mediaTypes = ["public.image", "public.movie"]
        picker.videoMaximumDuration = 15
        picker.videoQuality = .typeHigh
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: StoryCamera
        init(_ parent: StoryCamera) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.dismiss()
            if let url = info[.mediaURL] as? URL { parent.onPick(.video(url)) }
            else if let image = info[.originalImage] as? UIImage { parent.onPick(.photo(image)) }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Aufnehmen, Ort und Text ergänzen, teilen
struct StoryComposer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var media: StoriesStore.Media?
    @State private var showCamera = true
    @State private var caption = ""
    @State private var placeName: String?
    @State private var coordinate: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let media {
                    preview(media)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    HStack(spacing: 6) {
                        Image(systemName: "mappin.and.ellipse").foregroundStyle(Theme.accent)
                        Text(placeName ?? String(localized: "Ort wird ermittelt …")).font(.subheadline)
                        Spacer()
                    }
                    TextField("Text (optional)", text: $caption, axis: .vertical)
                        .lineLimit(1...3)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                        .onChange(of: caption) { _, new in if new.count > 140 { caption = String(new.prefix(140)) } }
                    Button {
                        Task { await share(media) }
                    } label: {
                        if app.stories.isPosting { ProgressView() } else { Label("Story teilen", systemImage: "paperplane.fill") }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(app.stories.isPosting || coordinate == nil)
                    Text("24 Stunden für deine Freunde sichtbar – an diesem Ort auf der Karte.")
                        .font(.footnote).foregroundStyle(Theme.muted)
                } else {
                    Spacer()
                    Button { showCamera = true } label: { Label("Aufnehmen", systemImage: "camera.fill") }
                        .buttonStyle(PrimaryButtonStyle())
                    Spacer()
                }
            }
            .padding(16)
            .background(Theme.ink.ignoresSafeArea())
            .navigationTitle("Neue Story")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } } }
            .fullScreenCover(isPresented: $showCamera) {
                StoryCamera { media = $0 }.ignoresSafeArea()
            }
            .task { await locate() }
        }
    }

    @ViewBuilder private func preview(_ media: StoriesStore.Media) -> some View {
        switch media {
        case .photo(let image): Image(uiImage: image).resizable().scaledToFill()
        case .video(let url): LoopingVideo(url: url)
        }
    }

    private func locate() async {
        guard let here = app.location.lastLocation else { return }
        coordinate = here.coordinate
        let mark = try? await CLGeocoder().reverseGeocodeLocation(here).first
        placeName = mark?.name ?? mark?.locality ?? String(localized: "Unterwegs")
    }

    private func share(_ media: StoriesStore.Media) async {
        guard let coordinate else { return }
        if await app.stories.post(media, caption: caption, placeName: placeName, at: coordinate) {
            app.show(String(localized: "Story geteilt"), isError: false)
            dismiss()
        }
    }
}

private struct LoopingVideo: View {
    let url: URL
    @State private var player: AVQueuePlayer?
    @State private var looper: AVPlayerLooper?

    var body: some View {
        VideoPlayer(player: player)
            .onAppear {
                let queue = AVQueuePlayer()
                looper = AVPlayerLooper(player: queue, templateItem: AVPlayerItem(url: url))
                player = queue
                queue.play()
            }
            .onDisappear { player?.pause() }
    }
}

// MARK: - Ansehen

/// Vollbild: Stories einer Person nacheinander. Tippen rechts = weiter, links = zurück.
struct StoryViewer: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    let stories: [StoriesStore.Story]
    @State private var index = 0
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var viewers: [StoriesStore.Viewer]?
    @State private var showViewers = false

    private var story: StoriesStore.Story? { stories.indices.contains(index) ? stories[index] : nil }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if let player {
                VideoPlayer(player: player).disabled(true)
            } else if failed {
                Text("Story nicht verfügbar").foregroundStyle(.white)
            } else {
                ProgressView().tint(.white)
            }
            HStack(spacing: 0) {
                Color.clear.contentShape(Rectangle()).onTapGesture { step(-1) }
                Color.clear.contentShape(Rectangle()).onTapGesture { step(1) }
            }
            if let story { overlay(story) }
        }
        .statusBarHidden()
        .task(id: index) { await play() }
        .task(id: index) {
            viewers = nil
            if let story, story.userId == app.profile?.id { viewers = await app.stories.viewers(of: story) }
        }
        .sheet(isPresented: $showViewers) {
            NavigationStack {
                List(viewers ?? []) { v in
                    let friend = app.friends.rows.first { $0.friendId == v.viewer }
                    HStack(spacing: 12) {
                        Avatar(initials: friend?.initials ?? "?", color: FriendPalette.color(for: v.viewer), size: 36, userId: v.viewer)
                        Text(friend?.displayName ?? String(localized: "Jemand"))
                        Spacer()
                        Text(ActivityFormat.time(v.seenAt)).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .navigationTitle("Gesehen von")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { showViewers = false } } }
            }
            .presentationDetents([.medium, .large])
        }
    }

    private func overlay(_ story: StoriesStore.Story) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ForEach(stories.indices, id: \.self) { i in
                    Capsule().fill(.white.opacity(i <= index ? 1 : 0.35)).frame(height: 3)
                }
            }
            HStack(spacing: 10) {
                Avatar(initials: String(story.displayName.prefix(1)), color: FriendPalette.color(for: story.userId), size: 36, userId: story.userId)
                VStack(alignment: .leading, spacing: 1) {
                    Text(story.userId == app.profile?.id ? String(localized: "Du") : story.displayName).font(.subheadline.weight(.semibold))
                    Text([story.placeName, ActivityFormat.time(story.createdAt)].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption)
                        .opacity(0.8)
                }
                Spacer()
                if story.userId == app.profile?.id {
                    Button {
                        Task { await app.stories.delete(story); if index >= stories.count - 1 { dismiss() } }
                    } label: { Image(systemName: "trash").padding(8) }
                    .accessibilityLabel("Story löschen")
                }
                Button { dismiss() } label: { Image(systemName: "xmark").font(.headline).padding(8) }
                    .accessibilityLabel("Schließen")
            }
            Spacer()
            if let caption = story.caption {
                Text(caption)
                    .font(.body.weight(.medium))
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(.black.opacity(0.5)))
                    .frame(maxWidth: .infinity)
            }
            if story.userId == app.profile?.id, let viewers {
                Button { showViewers = true } label: {
                    Label(viewers.count == 1 ? String(localized: "Gesehen von 1") : String(localized: "Gesehen von \(viewers.count)"), systemImage: "eye")
                        .font(.subheadline.weight(.semibold))
                }
                .disabled(viewers.isEmpty)
            }
            Button {
                let place = Place(id: "story-\(story.id)", name: story.placeName ?? String(localized: "Story-Ort"), address: nil, coordinate: story.coordinate)
                dismiss()
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    await app.navigation.planRoute(to: place)
                }
            } label: { Label("Hin navigieren", systemImage: "arrow.triangle.turn.up.right.diamond") }
            .buttonStyle(SecondaryButtonStyle())
        }
        .foregroundStyle(.white)
        .padding(16)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        if next < 0 { return }
        if next >= stories.count { dismiss(); return }
        index = next
    }

    private func play() async {
        player?.pause()
        image = nil; player = nil; failed = false
        guard let story else { return }
        guard let url = await app.stories.file(for: story), !Task.isCancelled else { failed = true; return }
        app.stories.markSeen(story)
        if story.isVideo {
            let item = AVPlayerItem(url: url)
            let p = AVPlayer(playerItem: item)
            player = p
            p.play()
            for await _ in NotificationCenter.default.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) { break }
        } else {
            image = UIImage(contentsOfFile: url.path)
            try? await Task.sleep(for: .seconds(6))
        }
        if !Task.isCancelled { step(1) }
    }
}

// MARK: - Konvoi-Feed und Fahrten

/// Laufender Konvoi oben, darunter frühere Fahrten
struct TripsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    private var feed: ConvoyFeed { ConvoyFeed.shared }

    var body: some View {
        NavigationStack {
            List {
                if let key = feed.key {
                    Section("Jetzt") {
                        NavigationLink { ConvoyFeedView(key: key, title: String(localized: "Konvoi")) } label: {
                            Label("Konvoi-Feed", systemImage: "car.2.fill")
                        }
                    }
                }
                Section("Fahrten") {
                    if feed.trips.isEmpty {
                        Text("Noch keine gemeinsamen Fahrten. Fährst du mit Freunden zum selben Ziel, entsteht hier eine Chronik.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ForEach(feed.trips) { trip in
                        NavigationLink {
                            ConvoyFeedView(key: trip.convoyKey, title: trip.destName ?? String(localized: "Fahrt"))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(trip.destName ?? String(localized: "Fahrt")).font(Theme.title(15))
                                Text("\(trip.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(names(trip.members))")
                                    .font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.ink)
            .navigationTitle("Fahrten")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fertig") { dismiss() } } }
            .task { await feed.loadTrips() }
        }
    }

    private func names(_ ids: [UUID]) -> String {
        ids.compactMap { id in app.friends.rows.first { $0.friendId == id }?.firstName }.joined(separator: ", ")
    }
}

struct ConvoyFeedView: View {
    @Environment(AppModel.self) private var app
    let key: String
    let title: String
    private var feed: ConvoyFeed { ConvoyFeed.shared }

    var body: some View {
        List(feed.shownKey == key ? feed.entries : []) { e in
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(e.kind))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(feed.describe(e)).font(.subheadline)
                    Text(ActivityFormat.time(e.createdAt)).font(.caption).foregroundStyle(Theme.muted)
                }
                Spacer()
                if e.kind == .story, let id = e.storyId {
                    if let story = app.stories.stories.first(where: { $0.id == id }) {
                        Button("Ansehen") { app.stories.viewing = [story] }.font(.footnote.weight(.semibold))
                    } else {
                        Text("abgelaufen").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .overlay {
            if feed.shownKey == key, feed.entries.isEmpty { ProgressView() }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await feed.show(key) }
        .onDisappear { Task { await feed.show(nil) } }
        .fullScreenCover(isPresented: Binding(get: { app.stories.viewing != nil }, set: { if !$0 { app.stories.viewing = nil } })) {
            if let list = app.stories.viewing { StoryViewer(stories: list).environment(app) }
        }
    }

    private func symbol(_ kind: ConvoyFeed.Kind) -> String {
        switch kind {
        case .joined: "car.fill"
        case .pause: "cup.and.saucer.fill"
        case .charge: "bolt.car.fill"
        case .message: "bubble.left.fill"
        case .story: "camera.fill"
        case .arrived: "flag.checkered"
        }
    }
}
