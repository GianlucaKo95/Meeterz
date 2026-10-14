import SwiftUI
import UIKit

/// Foto für das Profilbild zuschneiden: verschieben und zoomen, runder Ausschnitt.
/// Gibt ein quadratisches Bild (256 × 256 px) zurück.
struct AvatarCropItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct AvatarCropView: View {
    let image: UIImage
    let onDone: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private let maxScale: CGFloat = 5
    private let outputEdge: CGFloat = 256

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height * 0.62) - 32
            VStack(spacing: 24) {
                Text("Ausschnitt wählen")
                    .font(Theme.title(18))
                    .padding(.top, 24)

                cropArea(side: side)
                    .frame(width: side, height: side)

                Text("Mit zwei Fingern zoomen, zum Verschieben ziehen.")
                    .font(.footnote).foregroundStyle(Theme.muted)

                Spacer()

                HStack(spacing: 12) {
                    Button("Abbrechen") { dismiss() }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("Fertig") {
                        onDone(render(side: side))
                        dismiss()
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .background(Theme.ink.ignoresSafeArea())
    }

    // MARK: Ausschnitt

    /// Bildgröße bei Zoom 1: die kürzere Seite füllt den Ausschnitt
    private func baseSize(side: CGFloat) -> CGSize {
        let factor = side / min(image.size.width, image.size.height)
        return CGSize(width: image.size.width * factor, height: image.size.height * factor)
    }

    private func clamped(_ offset: CGSize, scale: CGFloat, side: CGFloat) -> CGSize {
        let base = baseSize(side: side)
        let maxX = max(0, (base.width * scale - side) / 2)
        let maxY = max(0, (base.height * scale - side) / 2)
        return CGSize(width: min(max(offset.width, -maxX), maxX),
                      height: min(max(offset.height, -maxY), maxY))
    }

    private func cropArea(side: CGFloat) -> some View {
        let base = baseSize(side: side)
        return ZStack {
            Image(uiImage: image)
                .resizable()
                .frame(width: base.width * scale, height: base.height * scale)
                .offset(offset)
            // Abdunklung außerhalb des Kreises
            CircleCutout()
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
            Circle().stroke(Theme.accent, lineWidth: 2).allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    let proposed = CGSize(width: lastOffset.width + value.translation.width,
                                          height: lastOffset.height + value.translation.height)
                    offset = clamped(proposed, scale: scale, side: side)
                }
                .onEnded { _ in lastOffset = offset }
        )
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    scale = min(max(lastScale * value.magnification, 1), maxScale)
                    offset = clamped(offset, scale: scale, side: side)
                }
                .onEnded { _ in
                    lastScale = scale
                    lastOffset = offset
                }
        )
    }

    // MARK: Ergebnis

    private func render(side: CGFloat) -> UIImage {
        let base = baseSize(side: side)
        let shown = CGSize(width: base.width * scale, height: base.height * scale)
        let factor = outputEdge / side
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: outputEdge, height: outputEdge), format: format).image { _ in
            let origin = CGPoint(x: (side / 2 + offset.width - shown.width / 2) * factor,
                                 y: (side / 2 + offset.height - shown.height / 2) * factor)
            image.draw(in: CGRect(origin: origin, size: CGSize(width: shown.width * factor, height: shown.height * factor)))
        }
    }
}

/// Quadrat mit rundem Loch (Even-Odd-Füllung)
private struct CircleCutout: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.addRect(rect)
        path.addEllipse(in: rect)
        return path
    }
}
