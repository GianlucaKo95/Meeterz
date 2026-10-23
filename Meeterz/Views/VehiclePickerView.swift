import SwiftUI

/// Fahrzeug fürs E-Auto wählen: alle Fahrzeuge aus Open EV Data nach Marke, dazu „Andere“ mit eigenen Werten.
struct VehiclePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: EVVehicle?
    @State private var query = ""

    private var groups: [(brand: String, vehicles: [EVVehicle])] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return EVCatalog.byBrand }
        return EVCatalog.byBrand.compactMap { group in
            let hits = group.vehicles.filter { "\($0.brand) \($0.name) \($0.year ?? 0)".lowercased().contains(q) }
            return hits.isEmpty ? nil : (group.brand, hits)
        }
    }

    var body: some View {
        List {
            if query.isEmpty {
                Section {
                    NavigationLink {
                        CustomVehicleForm(selection: $selection) { dismiss() }
                    } label: {
                        HStack {
                            Label("Andere", systemImage: "slider.horizontal.3")
                            Spacer()
                            if selection?.isCustom == true { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                        }
                    }
                } footer: {
                    Text("Dein Auto fehlt? Batterie, Verbrauch und Ladeleistung selbst eintragen.")
                }
                .listRowBackground(Theme.panel)
            }
            ForEach(groups, id: \.brand) { group in
                Section(group.brand) {
                    ForEach(group.vehicles) { vehicle in
                        Button {
                            selection = vehicle
                            EVSettings.vehicle = vehicle
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(vehicle.name + (vehicle.year.map { " (\($0))" } ?? ""))
                                        .foregroundStyle(Theme.text)
                                    Text(vehicle.specs).font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if selection?.id == vehicle.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(Theme.panel)
            }
            Section {
                EmptyView()
            } footer: {
                Text("\(EVCatalog.attribution). Werte sind Durchschnittswerte; Meeterz lernt mit der Zeit aus deinen Fahrten.")
            }
            .listRowBackground(Theme.panel)
        }
        .searchable(text: $query, prompt: "Marke oder Modell")
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Fahrzeug")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// „Andere“: eigene Werte, falls das Auto nicht im Katalog ist
private struct CustomVehicleForm: View {
    @Binding var selection: EVVehicle?
    let done: () -> Void
    @State private var battery: Double
    @State private var consumption: Double
    @State private var dcMax: Double

    init(selection: Binding<EVVehicle?>, done: @escaping () -> Void) {
        _selection = selection
        self.done = done
        let current = selection.wrappedValue
        _battery = State(initialValue: current?.battery ?? 60)
        _consumption = State(initialValue: current?.consumption ?? 18)
        _dcMax = State(initialValue: current?.dcMax ?? 100)
    }

    var body: some View {
        Form {
            Section {
                Stepper(value: $battery, in: 10...200, step: 1) {
                    LabeledContent("Nutzbare Batterie", value: "\(Int(battery)) kWh")
                }
                Stepper(value: $consumption, in: 10...40, step: 0.5) {
                    LabeledContent("Verbrauch", value: String(format: "%.1f kWh/100 km", consumption).replacingOccurrences(of: ".", with: ","))
                }
                Stepper(value: $dcMax, in: 20...350, step: 5) {
                    LabeledContent("Max. Schnellladen (DC)", value: "\(Int(dcMax)) kW")
                }
            } footer: {
                Text("Reichweite bei 100 %: ca. \(Int(battery / consumption * 100)) km")
            }
            .listRowBackground(Theme.panel)
            Section {
                Button("Übernehmen") {
                    let vehicle = EVVehicle.custom(battery: battery, consumption: consumption, dcMax: dcMax)
                    selection = vehicle
                    EVSettings.vehicle = vehicle
                    done()
                }
                .accessibilityIdentifier("vehicle-custom-save")
            }
            .listRowBackground(Theme.panel)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .navigationTitle("Andere")
        .navigationBarTitleDisplayMode(.inline)
    }
}
