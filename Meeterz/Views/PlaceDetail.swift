import SwiftUI
import MapKit
import CoreLocation

/// Apples Ortsdetail-Ansicht (Öffnungszeiten, Bewertungen, Fotos, Anrufen …) – ab iOS 18.
struct PlaceDetailItem: Identifiable {
    let id = UUID()
    let mapItem: MKMapItem
}

private struct AppleDetailView: UIViewControllerRepresentable {
    let mapItem: MKMapItem

    func makeUIViewController(context: Context) -> MKMapItemDetailViewController {
        MKMapItemDetailViewController(mapItem: mapItem, displaysMap: false)
    }

    func updateUIViewController(_ controller: MKMapItemDetailViewController, context: Context) {}
}

struct PlaceDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let item: PlaceDetailItem
    /// Wird nach dem Schließen aufgerufen
    let navigate: (Place) -> Void

    var body: some View {
        VStack(spacing: 0) {
            AppleDetailView(mapItem: item.mapItem)
            Button {
                let coordinate = item.mapItem.coordinate
                let place = Place(id: "apple-\(UUID().uuidString)", name: item.mapItem.name ?? "Ziel", address: nil, coordinate: coordinate)
                dismiss()
                navigate(place)
            } label: {
                Label("Hierhin navigieren", systemImage: "arrow.triangle.turn.up.right.diamond")
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(.regularMaterial)
        }
        .presentationDetents([.height(480), .large])
        .presentationDragIndicator(.visible)
    }
}

enum ApplePlaces {
    /// Findet zu einem Ort (z. B. Suchtreffer von Mapbox) den passenden Eintrag in Apples Orten.
    static func mapItem(for place: Place) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place.name
        request.region = MKCoordinateRegion(center: place.coordinate, latitudinalMeters: 400, longitudinalMeters: 400)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        let target = CLLocation(latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
        return response.mapItems
            .map { ($0, CLLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude).distance(from: target)) }
            .filter { $0.1 < 150 }
            .min { $0.1 < $1.1 }?.0
    }
}

extension MKMapItem {
    /// Ab iOS 26 gibt es `location`, `placemark` ist dort veraltet; davor nur `placemark`.
    var coordinate: CLLocationCoordinate2D {
        if #available(iOS 26.0, *) { return location.coordinate }
        return placemark.coordinate
    }
}
