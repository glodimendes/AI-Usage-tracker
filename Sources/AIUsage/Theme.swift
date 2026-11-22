import SwiftUI
import AppKit

extension Color {
    /// Hunter green (#355E3B); slightly lighter in dark mode so it stays visible.
    static let hunter = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0x4F / 255, green: 0x8A / 255, blue: 0x5A / 255, alpha: 1)
            : NSColor(red: 0x35 / 255, green: 0x5E / 255, blue: 0x3B / 255, alpha: 1)
    })
}

struct Bar: View {
    var fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(Color.hunter).frame(width: max(g.size.width * fraction, fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 4)
    }
}
