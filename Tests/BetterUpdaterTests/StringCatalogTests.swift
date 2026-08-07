import XCTest

/// The catalog silently rots when a source string is reworded: the old key keeps
/// its translations, the new one falls back to English in every locale. This
/// caught eleven keys still carrying a previous host app's name.
final class StringCatalogTests: XCTestCase {
    func testCatalogHoldsExactlyTheKeysTheSourceEmits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = try FileManager.default
            .contentsOfDirectory(at: root.appending(path: "Sources/BetterUpdater"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        let catalog = root.appending(path: "Sources/BetterUpdater/Resources/Updater.xcstrings")
        let extracted = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "xcstrings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extracted) }

        try run(["xcstringstool", "extract", "--modern-localizable-strings", "-o", extracted.path] + sources.map(\.path))
        let synced = extracted.appending(path: "Updater.xcstrings")  // sync matches the table by file name
        try FileManager.default.copyItem(at: catalog, to: synced)
        let stringsdata = try FileManager.default
            .contentsOfDirectory(at: extracted, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "stringsdata" }
        try run(["xcstringstool", "sync", synced.path, "--stringsdata"] + stringsdata.map(\.path))

        // The lightweight extractor writes %arg where a real build writes the
        // typed specifier, so compare with every specifier collapsed to "%".
        func keys(_ url: URL, dropStale: Bool) throws -> Set<String> {
            let doc = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            let strings = doc["strings"] as! [String: [String: Any]]
            return Set(strings.compactMap { key, entry in
                if dropStale, entry["extractionState"] as? String == "stale" { return nil }
                return key.replacing(/%(@|arg|lld|d)/, with: "%")
            })
        }
        XCTAssertEqual(try keys(catalog, dropStale: false), try keys(synced, dropStale: true))
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        try XCTSkipUnless(process.terminationStatus == 0, "xcstringstool unavailable")
    }
}
