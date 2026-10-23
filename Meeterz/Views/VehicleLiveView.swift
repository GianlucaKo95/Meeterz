import SwiftUI

/// Einstellungen → E-Auto → Live-Daten: Gerätetoken fürs Home-Assistant-Add-on und aktueller Stand
struct VehicleLiveView: View {
    @Environment(AppModel.self) private var app
    @State private var busy = false
    @State private var confirmDisconnect = false

    private var store: VehicleStore { app.vehicle }

    var body: some View {
        Form {
            if let status = store.status {
                Section("Aktuell") {
                    if let soc = status.soc { LabeledContent("Akkustand", value: "\(Int(soc.rounded())) %") }
                    if let range = status.rangeKm { LabeledContent("Reichweite laut Auto", value: "\(Int(range)) km") }
                    if status.charging == true {
                        LabeledContent("Lädt", value: status.powerKw.map { "\(Int(abs($0).rounded())) kW" } ?? "ja")
                    }
                    if let t = status.extTemp { LabeledContent("Außentemperatur", value: "\(Int(t.rounded())) °C") }
                    LabeledContent("Stand", value: Self.relative(status.measuredAt))
                }
            }

            if let token = store.token {
                Section {
                    copyRow("Server-Adresse", VehicleStore.telemetryURL, id: "vehicle-url")
                    copyRow("Geräte-ID", token, id: "vehicle-token")
                } header: {
                    Text("Im Add-on eintragen")
                } footer: {
                    Text("Home Assistant → Add-ons → „MG to ABRP Bridge“ → Konfiguration: „meeterz_url“ und „meeterz_device_id“ einfügen und das Add-on neu starten. Beim Fahren kommt etwa alle 30 Sekunden ein neuer Wert, geparkt seltener.")
                }
                Section {
                    Button("Neue Geräte-ID erzeugen") { Task { busy = true; await store.connect(); busy = false } }
                    Button("Live-Daten trennen", role: .destructive) { confirmDisconnect = true }
                } footer: {
                    Text("Eine neue Geräte-ID macht die alte ungültig.")
                }
            } else {
                Section {
                    Button {
                        Task { busy = true; await store.connect(); busy = false }
                    } label: {
                        if busy { ProgressView() } else { Text("Live-Daten verbinden") }
                    }
                    .accessibilityIdentifier("vehicle-connect")
                } footer: {
                    Text("Meeterz übernimmt Akkustand, Reichweite und Ladezustand live aus deinem Auto – über das Home-Assistant-Add-on „MG to ABRP Bridge“ (iSMART). Damit entfällt die Akku-Eingabe in CarPlay, und die Ladeplanung rechnet mit echten Werten.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Live-Daten")
        .navigationBarTitleDisplayMode(.inline)
        .task { await store.refresh() }
        .refreshable { await store.refresh() }
        .confirmationDialog("Live-Daten trennen?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Trennen", role: .destructive) { Task { await store.disconnect() } }
        } message: {
            Text("Die Geräte-ID wird ungültig, gespeicherte Werte werden gelöscht.")
        }
    }

    private func copyRow(_ title: String, _ value: String, id: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            app.show("\(title) kopiert", isError: false)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(title).foregroundStyle(Theme.text)
                    Spacer()
                    Image(systemName: "doc.on.doc").foregroundStyle(Theme.accent)
                }
                Text(value).font(.caption.monospaced()).foregroundStyle(Theme.muted).lineLimit(2).textSelection(.enabled)
            }
        }
        .accessibilityIdentifier(id)
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}
