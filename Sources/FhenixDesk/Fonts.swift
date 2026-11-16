import CoreText
import Foundation

/// Instrument Sans and DM Mono, registered for this process at launch: from the app bundle's `Resources/Fonts`, or, for a
/// debug build run from the repo (`swift run`, snapshots), from the repo's own `Resources/Fonts`. A font that fails to
/// register leaves the system font in its place.
enum AppFonts {
    static let sans = "Instrument Sans"
    static let mono = "DM Mono"

    static func register() {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Resources/Fonts")
        let folders = [Bundle.main.resourceURL?.appending(path: "Fonts"), repo].compactMap { $0 }
        guard let folder = folders.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { return }
        for file in files where file.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(file as CFURL, .process, nil)
        }
    }
}
