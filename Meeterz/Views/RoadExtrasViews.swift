import SwiftUI
import CoreLocation

// MARK: - Stopp entlang der Route (iPhone; CarPlay: Suche → Kategorien)

/// Tankstelle, Ladesäule, Parkplatz, Essen, Café auf dem Weg – mit Strecke bis dorthin und Spritpreisen
struct StopSearchSheet: View {
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var kind: SearchService.Stopover = .gas
    @State private var found: [NavigationCoordinator.Stopover]?
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(app.navigation.isNavigating ? "Entlang der Route" : "In der Nähe").font(Theme.display(22))
            // Chips laufen bis an den Fensterrand (statt am Innenabstand hart abgeschnitten zu werden)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(SearchService.Stopover.allCases) { k in
                        Button { kind = k } label: {
                            Label(k.title, systemImage: k.symbol)
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 12).frame(height: 36)
                                .background(Capsule().fill(k == kind ? Theme.accent : Theme.panel))
                                .foregroundStyle(k == kind ? Theme.ink : Theme.text)
                        }
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.horizontal, -20)
            ScrollView {
                VStack(spacing: 8) {
                    if let errorText { Text(errorText).font(.footnote).foregroundStyle(Theme.muted) }
                    else if found == nil { ProgressView().padding() }
                    else if found?.isEmpty == true { Text("Nichts gefunden").foregroundStyle(Theme.muted).padding() }
                    ForEach(found ?? [], id: \.place.id) { s in
                        Button { pick(s.place) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.place.name).font(.headline).foregroundStyle(Theme.text)
                                Text(detail(s)).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                                if let price = s.price?.text, !price.isEmpty {
                                    Text(price).font(.footnote.weight(.semibold)).foregroundStyle(Theme.accent)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        }
                    }
                    if found?.contains(where: { $0.price != nil }) == true {
                        Text(FuelPrices.attribution).font(.caption2).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
        .task(id: kind) { await load() }
    }

    private func detail(_ s: NavigationCoordinator.Stopover) -> String {
        let me = app.location.lastLocation?.coordinate
        let away = s.ahead.map { String(localized: "nach \(ActivityFormat.distance($0))") }
            ?? me.map { ActivityFormat.distance(s.place.coordinate.distance(to: $0)) }
        return [away, s.place.address].compactMap { $0 }.joined(separator: " · ")
    }

    private func load() async {
        found = nil
        errorText = nil
        guard let me = app.location.lastLocation?.coordinate else { errorText = String(localized: "Standort unbekannt"); return }
        do { found = try await app.navigation.stopovers(kind, near: me) }
        catch { errorText = (error as? LocalizedError)?.errorDescription ?? String(localized: "Die Suche ist gerade nicht erreichbar.") }
    }

    private func pick(_ place: Place) {
        dismiss()
        Task {
            if app.navigation.isNavigating { await app.navigation.addStop(place) }
            else { await app.navigation.planRoute(to: place) }
        }
    }
}

// MARK: - Gefahr melden

struct HazardReportSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gefahr melden").font(Theme.display(22))
            Text("Andere Meeterz-Fahrer hinter dir werden eine Stunde lang gewarnt.")
                .font(.footnote).foregroundStyle(Theme.muted)
          ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
                ForEach(HazardStore.Kind.allCases) { kind in
                    Button {
                        dismiss()
                        Task { await HazardStore.shared.report(kind) }
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: kind.symbol).font(.system(size: 24, weight: .semibold))
                            Text(kind.title).font(.footnote.weight(.semibold)).multilineTextAlignment(.center)
                                .lineLimit(2).minimumScaleFactor(0.85)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity)
                        .frame(height: 96)   // alle Kacheln gleich hoch, auch bei zweizeiligem Text
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
                        .foregroundStyle(Theme.text)
                    }
                }
            }
          }
        }
        .padding(20)
        .background(Theme.ink)
    }
}

// MARK: - Ankunft um … / Abfahrt ab …

/// Fahrt zeitlich planen: Ankunftszeit wählen (Meeterz rechnet die Abfahrt) oder Abfahrtszeit wählen (Meeterz rechnet
/// die Ankunft) – jeweils mit der für diese Uhrzeit üblichen Verkehrslage. Erinnerung 10 Min. vor der Abfahrt.
struct ArriveBySheet: View {
    let place: Place
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var leave = false
    @State private var time = Calendar.current.date(byAdding: .hour, value: 1, to: .now)!
    /// Berechnete Abfahrt bzw. (bei `leave`) Ankunft
    @State private var result: Date?
    @State private var calculating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(place.name).font(Theme.display(22)).lineLimit(1)
            Picker("", selection: $leave) {
                Text("Ankunft um …").tag(false)
                Text("Abfahrt ab …").tag(true)
            }
            .pickerStyle(.segmented)
            DatePicker(leave ? "Abfahrt" : "Ankunft", selection: $time, in: Date().addingTimeInterval(leave ? 5 * 60 : 15 * 60)...Date().addingTimeInterval(24 * 3600))
                .datePickerStyle(.compact)
            Group {
                if calculating { ProgressView() }
                else if let result {
                    Text(leave ? "Ankunft: \(Meetup.timeText(result))" : "Losfahren: \(Meetup.timeText(result))")
                        .font(.headline).foregroundStyle(Theme.accent)
                } else {
                    Text("Fahrzeit konnte nicht berechnet werden.").font(.footnote).foregroundStyle(Theme.muted)
                }
            }
            Text("Mit dem zu dieser Uhrzeit üblichen Verkehr. Du bekommst 10 Minuten vor der Abfahrt eine Erinnerung.")
                .font(.footnote).foregroundStyle(Theme.muted)
            Button("Erinnern") {
                Task {
                    await DepartureReminder.shared.plan(place, at: time, leave: leave)
                    app.show(String(localized: "Erinnerung für \(place.name) geplant."), isError: false)
                    dismiss()
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(result == nil)
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(Theme.ink)
        .presentationDetents([.height(420)])
        .task(id: "\(leave)|\(time.timeIntervalSince1970)") {
            calculating = true
            try? await Task.sleep(for: .milliseconds(400))   // beim Drehen am Rad nicht jede Minute rechnen
            guard !Task.isCancelled else { return }
            result = leave ? await DepartureReminder.shared.arrival(to: place, departAt: time)
                           : await DepartureReminder.shared.departure(to: place, arriveAt: time)
            calculating = false
        }
    }
}

// MARK: - Gespeicherte Listen

/// Ort in eine eigene Liste speichern (oder neue Liste anlegen)
struct SaveToListSheet: View {
    let place: Place
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var shared = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In Liste speichern").font(Theme.display(22))
            Text(place.name).foregroundStyle(Theme.muted)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(app.lists.own) { list in
                        Button {
                            Task { await app.lists.add(place, to: list); dismiss() }
                        } label: {
                            HStack {
                                Image(systemName: list.shared ? "person.2.fill" : "list.bullet")
                                Text(list.name).font(.headline)
                                Spacer()
                                Text("\(list.items.count)").foregroundStyle(Theme.muted)
                            }
                            .padding(12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                            .foregroundStyle(Theme.text)
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Neue Liste, z. B. Lieblingscafés", text: $newName)
                            .padding(12).background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                        Toggle("Mit Freunden teilen", isOn: $shared).tint(Theme.accent)
                        Button("Anlegen und speichern") {
                            let name = newName.trimmingCharacters(in: .whitespaces)
                            Task {
                                if let list = await app.lists.create(name, shared: shared) { await app.lists.add(place, to: list) }
                                dismiss()
                            }
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    .padding(.top, 8)
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
        .task { if !app.lists.loaded { await app.lists.refresh() } }
    }
}

/// Eine Liste: Orte antippen = auswählen; eigene Listen: teilen umschalten, Orte und Liste löschen
struct PlaceListView: View {
    let listId: UUID
    let onPick: (Place) -> Void
    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let list = app.lists.lists.first { $0.id == listId }
        let mine = list?.owner == app.lists.me
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(list?.name ?? "").font(Theme.display(22))
                Spacer()
                if mine, let list {
                    Menu {
                        Button(list.shared ? "Nicht mehr teilen" : "Mit Freunden teilen", systemImage: "person.2") {
                            Task { await app.lists.setShared(list, !list.shared) }
                        }
                        Button("Liste löschen", systemImage: "trash", role: .destructive) {
                            Task { await app.lists.delete(list); dismiss() }
                        }
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }
                }
            }
            if let list, !mine, let owner = app.friend(list.owner) {
                Text("Von \(owner.displayName)").font(.footnote).foregroundStyle(Theme.muted)
            } else if list?.shared == true {
                Text("Mit Freunden geteilt").font(.footnote).foregroundStyle(Theme.muted)
            }
            ScrollView {
                VStack(spacing: 8) {
                    if list?.items.isEmpty ?? true {
                        Text("Noch keine Orte. Tippe auf einen Ort und dann auf „In Liste speichern“.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                    ForEach(list?.items ?? []) { item in
                        PlaceRow(place: item.place, distance: app.location.lastLocation.map { item.place.coordinate.distance(to: $0.coordinate) },
                                 selected: false) { dismiss(); onPick(item.place) }
                            .contextMenu {
                                if mine {
                                    Button("Entfernen", systemImage: "trash", role: .destructive) { Task { await app.lists.remove(item) } }
                                }
                            }
                    }
                }
            }
        }
        .padding(20)
        .background(Theme.ink)
    }
}
