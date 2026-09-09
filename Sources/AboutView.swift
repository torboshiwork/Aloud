import SwiftUI
import AppKit

struct AboutView: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    /// Logo (paper-cut mic, no squircle padding) → app icon → SF symbol fallback.
    private var appIcon: Image {
        if let path = Bundle.main.path(forResource: "logo", ofType: "png"),
           let img = NSImage(contentsOfFile: path) {
            return Image(nsImage: img)
        }
        if let path = Bundle.main.path(forResource: "Aloud", ofType: "icns"),
           let img = NSImage(contentsOfFile: path) {
            return Image(nsImage: img)
        }
        return Image(systemName: "mic.circle.fill")
    }

    var body: some View {
        VStack(spacing: 14) {
            appIcon
                .resizable()
                .scaledToFit()
                .frame(width: 110, height: 110)
                .shadow(color: Color(red: 0.2, green: 0.5, blue: 0.95).opacity(0.4), radius: 14, y: 6)

            Text("Aloud")
                .font(.title2).bold()
            Text("Version \(version)")
                .font(.caption)
                .foregroundColor(.secondary)

            Text("Speak, and your Mac types for you.\nHold Fn to talk — transcribed by Whisper, polished by AI.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)

            Divider().padding(.horizontal, 30)

            VStack(spacing: 4) {
                Text("Created by")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("torboshi")
                    .font(.headline)
                Text("Developer · Photographer · Bangkok")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            HStack(spacing: 14) {
                Link("Instagram", destination: URL(string: "https://www.instagram.com/torboshi")!)
                Link("GitHub", destination: URL(string: "https://github.com/torboshiwork/Aloud")!)
            }
            .font(.callout)

            // The upstream project this is built on. Keep the credit and the link — the
            // original carries no licence, so attribution is the least this owes it.
            VStack(spacing: 2) {
                Text("Built on")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Link("WhisperApp by Gamezxz",
                     destination: URL(string: "https://github.com/Gamezxz/WhisperApp")!)
                    .font(.caption)
            }

            Text("© 2026 torboshi — free & open source")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(28)
        .frame(width: 340)
    }
}
