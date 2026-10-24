import Foundation
import UIKit
import CarPlay

/// CarPlay: Freunde-Knopf öffnet eine Liste – alle ein-/ausblenden, je Freund auf der Karte zeigen,
/// hinfahren, Bescheid geben oder nur auf meiner Karte ausblenden.
extension CarPlayController {
    func showFriendsMenu() {
        CarPlayUI.shared.push(friendsMenuTemplate(), animated: true)
    }

    private func friendsMenuTemplate() -> CPListTemplate {
        let app = AppModel.shared
        let all = app.friendsOnMapIncludingPassengers
        let passengers = Passengers.shared
        let visibleCount = all.filter { !passengers.riding.contains($0.friend.friendId) }.count
        let config = UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold)

        let toggle = CPListItem(
            text: allFriendsVisible ? "Alle ausblenden" : "Alle einblenden",
            detailText: allFriendsVisible ? "\(visibleCount) sichtbar" : "alle ausgeblendet",
            image: UIImage(systemName: allFriendsVisible ? "eye.slash" : "eye", withConfiguration: config))
        toggle.handler = { [weak self] _, done in
            guard let self else { done(); return }
            setAllFriendsVisible(!allFriendsVisible)
            done()
            CarPlayUI.shared.pop(animated: true)
        }

        let me = app.location.lastLocation
        let items: [CPListItem] = all.map { item in
            let f = item.friend
            let hidden = passengers.riding.contains(f.friendId)
            let riding = hidden && !passengers.isHiddenForMe(f.friendId)
            var detail: [String] = []
            if riding { detail.append("fährt mit") }
            else if let route = app.routes.friendRoutes[f.friendId] {
                detail.append(route.destinationName.map { "fährt nach \($0)" } ?? "unterwegs")
            } else if let me {
                detail.append(Format.distance(item.position.coordinate.distance(to: me.coordinate)))
            }
            if item.position.age > 120 { detail.append(Format.age(item.position.age)) }
            if hidden { detail.append("ausgeblendet") }
            let image = AvatarRenderer.image(initials: f.initials, color: FriendPalette.uiColor(for: f.friendId),
                                             faded: hidden, photo: app.avatars.image(for: f.friendId))
            let row = CPListItem(text: f.displayName.split(separator: " ").first.map(String.init) ?? f.displayName,
                                 detailText: detail.joined(separator: " · "), image: image,
                                 accessoryImage: UIImage(systemName: hidden ? "eye.slash" : "eye"), accessoryType: .none)
            row.handler = { [weak self] _, done in
                self?.showFriendActions(item)
                done()
            }
            return row
        }

        var sections = [CPListSection(items: [toggle])]
        if !items.isEmpty { sections.append(CPListSection(items: items, header: "Freunde", sectionIndexTitle: nil)) }
        return CPListTemplate(title: "Freunde", sections: sections)
    }

    private func showFriendActions(_ item: AppModel.FriendOnMap) {
        let f = item.friend
        let first = f.displayName.split(separator: " ").first.map(String.init) ?? f.displayName
        let hidden = Passengers.shared.riding.contains(f.friendId)
        let controller = manager.interfaceController
        let close: () -> Void = { CarPlayUI.shared.dismiss(animated: true) }

        let show = CPAlertAction(title: "Auf Karte zeigen", style: .default) { [weak self] _ in
            close()
            CarPlayUI.shared.popToRoot(animated: true)
            if hidden { Passengers.shared.setHiddenForMe(f.friendId, false); self?.refreshFriendsAfterPassengerChange() }
            if self?.allFriendsVisible == false { self?.setAllFriendsVisible(true) }
            self?.focusFriend(item.position.coordinate)
        }
        let drive = CPAlertAction(title: "Hinfahren", style: .default) { [weak self] _ in
            close()
            CarPlayUI.shared.popToRoot(animated: true)
            self?.startGuidance(to: Place(id: "friend-\(f.friendId)", name: f.displayName, address: nil,
                                          coordinate: item.position.coordinate), showProgress: true)
        }
        let message = CPAlertAction(title: "Kurz Bescheid geben", style: .default) { [weak self] _ in
            close()
            self?.showQuickReplies(to: [f.friendId], meetupId: nil)
        }
        let toggle = CPAlertAction(title: hidden ? "Einblenden" : "Auf meiner Karte ausblenden",
                                   style: hidden ? .default : .destructive) { [weak self] _ in
            close()
            Passengers.shared.setHiddenForMe(f.friendId, !hidden)
            self?.refreshFriendsAfterPassengerChange()
            CarPlayUI.shared.pop(animated: true)
        }
        let cancel = CPAlertAction(title: "Abbrechen", style: .cancel) { _ in close() }
        let sheet = CPActionSheetTemplate(title: first, message: hidden ? "Auf deiner Karte ausgeblendet – \(first) sieht dich weiterhin" : nil,
                                          actions: [show, drive, message, toggle, cancel])
        CarPlayUI.shared.present(sheet, animated: true)
    }
}
