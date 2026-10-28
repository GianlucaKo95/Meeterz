import Foundation
import AppIntents
import CoreLocation

// MARK: Siri und Kurzbefehle
//
// Beispiele: „Navigiere mit Meeterz zu Lisa“, „Wo ist Lisa in Meeterz?“, „Mit Meeterz nach Hause“,
// „Standort mit Meeterz teilen“, „Meeterz Inkognito“. Funktioniert auch im Auto über CarPlay.

/// Ein angenommener Freund
struct FriendEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Freund")
    static var defaultQuery = FriendQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct FriendQuery: EntityStringQuery {
    @MainActor
    private func all() async -> [FriendEntity] {
        let app = AppModel.shared
        if app.friends.accepted.isEmpty { await app.friends.refresh() }
        return app.friends.accepted.map { FriendEntity(id: $0.friendId, name: $0.displayName) }
    }

    func entities(for identifiers: [UUID]) async throws -> [FriendEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FriendEntity] {
        let needle = string.lowercased()
        return await all().filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [FriendEntity] { await all() }
}

/// Zuhause, Arbeit und eigene Favoriten
struct FavoriteEntity: AppEntity {
    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Favorit")
    static var defaultQuery = FavoriteQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct FavoriteQuery: EntityStringQuery {
    @MainActor
    private func all() -> [FavoriteEntity] {
        let f = AppModel.shared.favorites
        return ([f.home, f.work].compactMap { $0 } + f.others).map { FavoriteEntity(id: $0.id.uuidString, name: $0.label) }
    }

    func entities(for identifiers: [String]) async throws -> [FavoriteEntity] {
        await all().filter { identifiers.contains($0.id) }
    }

    func entities(matching string: String) async throws -> [FavoriteEntity] {
        let needle = string.lowercased()
        return await all().filter { $0.name.lowercased().contains(needle) }
    }

    func suggestedEntities() async throws -> [FavoriteEntity] { await all() }
}

/// Dauer für „Standort teilen“
enum ShareDurationOption: String, AppEnum {
    case fifteenMinutes, oneHour, untilArrival, always

    static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Dauer")
    static var caseDisplayRepresentations: [ShareDurationOption: DisplayRepresentation] = [
        .fifteenMinutes: "15 Minuten",
        .oneHour: "1 Stunde",
        .untilArrival: "bis zur Ankunft",
        .always: "unbegrenzt",
    ]

    var mode: SharingMode {
        switch self {
        case .fifteenMinutes: .fifteenMinutes
        case .oneHour: .oneHour
        case .untilArrival: .untilArrival
        case .always: .always
        }
    }
}

// MARK: Navigation

@MainActor
private func startRoute(to place: Place) async {
    // Im Auto direkt auf CarPlay (Vorschau bzw. Zwischenstopp), sonst Vorschau auf dem iPhone
    if CarPlayController.shared.isConnected {
        CarPlayController.shared.go(to: place)
    } else {
        await AppModel.shared.navigation.planRoute(to: place)
    }
}

struct NavigateToFriendIntent: AppIntent {
    static var title: LocalizedStringResource = "Zu Freund navigieren"
    static var description = IntentDescription("Plant eine Route zum aktuellen Standort eines Freundes.")
    static var openAppWhenRun = true

    @Parameter(title: "Freund") var friend: FriendEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let item = AppModel.shared.friendsOnMap.first(where: { $0.friend.friendId == friend.id }) else {
            return .result(dialog: "\(friend.name) teilt gerade keinen Standort.")
        }
        let place = Place(id: "friend-\(friend.id)", name: friend.name, address: nil, coordinate: item.position.coordinate)
        await startRoute(to: place)
        return .result(dialog: "Route zu \(friend.name).")
    }
}

struct NavigateToFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Zu Favorit navigieren"
    static var description = IntentDescription("Plant eine Route nach Hause, zur Arbeit oder zu einem Favoriten.")
    static var openAppWhenRun = true

    @Parameter(title: "Favorit") var favorite: FavoriteEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let fav = AppModel.shared.favorites.items.first(where: { $0.id.uuidString == favorite.id }) else {
            return .result(dialog: "Diesen Favoriten gibt es nicht mehr.")
        }
        await startRoute(to: fav.place)
        return .result(dialog: "Route zu \(fav.label).")
    }
}

// MARK: Wo ist …?

struct WhereIsFriendIntent: AppIntent {
    static var title: LocalizedStringResource = "Wo ist ein Freund?"
    static var description = IntentDescription("Sagt, wie weit ein Freund entfernt ist und wohin er fährt.")

    @Parameter(title: "Freund") var friend: FriendEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        let first = friend.name.split(separator: " ").first.map(String.init) ?? friend.name
        guard let item = app.friendsOnMap.first(where: { $0.friend.friendId == friend.id }) else {
            return .result(dialog: "\(first) teilt gerade keinen Standort.")
        }
        var parts: [String] = []
        if let me = app.location.lastLocation?.coordinate {
            parts.append(String(localized: "\(first) ist \(Format.distance(item.position.coordinate.distance(to: me))) entfernt"))
        } else {
            parts.append(String(localized: "\(first) ist auf der Karte"))
        }
        if item.position.age > 120 { parts.append(String(localized: "Stand \(Format.age(item.position.age))")) }
        if let route = app.routes.friendRoutes[friend.id] {
            let target = route.destinationName.map { String(localized: "nach \($0)") } ?? String(localized: "zu einem Ziel")
            parts.append(String(localized: "unterwegs \(target), Ankunft \(Format.time.string(from: route.eta))"))
        }
        return .result(dialog: "\(parts.joined(separator: ", ")).")
    }
}

// MARK: Teilen und Inkognito

struct ShareLocationIntent: AppIntent {
    static var title: LocalizedStringResource = "Standort teilen"
    static var description = IntentDescription("Teilt deinen Standort mit deinen Freunden für eine bestimmte Zeit.")

    @Parameter(title: "Dauer", default: .oneHour) var duration: ShareDurationOption

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.shareLocation(for: duration.mode)
        guard AppModel.shared.profile?.isSharingNow == true else {
            return .result(dialog: "Das hat nicht geklappt. Öffne Meeterz und versuche es dort.")
        }
        return .result(dialog: "\(duration.mode.explanation)")
    }
}

struct PauseSharingIntent: AppIntent {
    static var title: LocalizedStringResource = "Teilen pausieren"
    static var description = IntentDescription("Freunde sehen deinen Standort nicht mehr, bis du wieder teilst.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await AppModel.shared.auth.setSharing(false)
        return .result(dialog: "Teilen pausiert.")
    }
}

struct IncognitoIntent: AppIntent {
    static var title: LocalizedStringResource = "Inkognito"
    static var description = IntentDescription("Freunde sehen weder deinen Standort noch deine Route. Nochmal aufrufen beendet es.")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let app = AppModel.shared
        if app.profile?.isIncognito == true {
            await app.stopIncognito()
            return .result(dialog: "Inkognito beendet – du bist wieder sichtbar.")
        }
        await app.startIncognito(for: 3600)
        return .result(dialog: "Inkognito für eine Stunde.")
    }
}

/// Für eine Kurzbefehl-Automation „Wenn CarPlay verbunden“: startet Meeterz unsichtbar im Hintergrund, damit
/// Dashboard und CarPlay-Ansicht sofort da sind – auch nachdem die App weggewischt wurde. iOS startet weggewischte
/// Apps von selbst nicht mehr, ein vom Nutzer eingerichteter Kurzbefehl darf das aber.
struct StartForCarPlayIntent: AppIntent {
    static var title: LocalizedStringResource = "Für CarPlay starten"
    static var description = IntentDescription("Startet Meeterz im Hintergrund, ohne die App zu öffnen. Ideal als Automation „Wenn CarPlay verbunden“.")
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult {
        Diag.log("App per Kurzbefehl gestartet (CarPlay-Automation)")
        AppModel.shared.startWithoutPhoneUI("Kurzbefehl")
        return .result()
    }
}

// MARK: Sätze für Siri

struct MeeterzShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NavigateToFriendIntent(), phrases: [
            "Navigiere mit \(.applicationName) zu \(\.$friend)",
            "Mit \(.applicationName) zu \(\.$friend)",
            "Fahr mit \(.applicationName) zu \(\.$friend)",
        ], shortTitle: "Zu Freund", systemImageName: "person.crop.circle")

        AppShortcut(intent: NavigateToFavoriteIntent(), phrases: [
            "Navigiere mit \(.applicationName) zu \(\.$favorite)",
            "Mit \(.applicationName) nach \(\.$favorite)",
            "Mit \(.applicationName) zur \(\.$favorite)",
        ], shortTitle: "Zu Favorit", systemImageName: "star")

        AppShortcut(intent: WhereIsFriendIntent(), phrases: [
            "Wo ist \(\.$friend) in \(.applicationName)",
            "Wo ist \(\.$friend) bei \(.applicationName)",
            "\(.applicationName) wo ist \(\.$friend)",
        ], shortTitle: "Wo ist …?", systemImageName: "location.magnifyingglass")

        AppShortcut(intent: ShareLocationIntent(), phrases: [
            "Standort mit \(.applicationName) teilen",
            "\(.applicationName) Standort teilen",
        ], shortTitle: "Standort teilen", systemImageName: "location.fill")

        AppShortcut(intent: PauseSharingIntent(), phrases: [
            "\(.applicationName) Teilen pausieren",
            "Teilen in \(.applicationName) pausieren",
        ], shortTitle: "Teilen pausieren", systemImageName: "pause.circle")

        AppShortcut(intent: IncognitoIntent(), phrases: [
            "\(.applicationName) Inkognito",
            "Inkognito in \(.applicationName)",
        ], shortTitle: "Inkognito", systemImageName: "eye.slash")
    }
}
