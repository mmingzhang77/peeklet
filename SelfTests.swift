import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

private enum TestFailure: Error {
    case failed(String)
}

func runSelfTests() throws {
    var checks = 0
    func check(_ condition: Bool, _ label: String) throws {
        guard condition else {
            fputs("FAIL: \(label)\n", stderr)
            throw TestFailure.failed(label)
        }
        checks += 1
    }
    func expectFailure(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks += 1; return }
        fputs("FAIL: \(label)\n", stderr)
        throw TestFailure.failed(label)
    }

    var session = PeekSession()
    try check(session.phase == .hidden, "starts hidden")
    session.begin(at: 100)
    try check(session.update(at: 100.1, buttonDown: true, pointerInside: true) == .armed, "short hold")
    try check(session.update(at: 100.2, buttonDown: true, pointerInside: true) == .visible, "long hold")
    try check(session.update(at: 100.21, buttonDown: false, pointerInside: true) == .hidden, "release")
    try check(session.update(at: 100.3, buttonDown: true, pointerInside: true) == .hidden, "no spontaneous reveal")
    session.begin(at: 200)
    try check(session.update(at: 200.2, buttonDown: true, pointerInside: false) == .hidden, "pointer exit")
    session.begin(at: 300)
    try check(session.update(at: 310.1, buttonDown: true, pointerInside: true) == .hidden, "hold timeout")
    session.begin(at: 400)
    session.end()
    try check(session.update(at: 400.2, buttonDown: true, pointerInside: true) == .hidden, "cancel")

    let screen = NSRect(x: -1440, y: 0, width: 1440, height: 900)
    let window = NSRect(x: -2000, y: 890, width: 180, height: 270)
    try check(screen.contains(fittedRect(window, within: screen)), "fit to negative-origin screen")
    let edge = ViewerLayout.entranceEdges[ViewerLayout.defaultEntranceIndex]
    try check(edge == 36 && ViewerLayout.entranceEdges.contains(24), "entrance sizes")
    try check(ViewerLayout.entranceLevel.rawValue < NSWindow.Level.popUpMenu.rawValue, "below system menu")
    try check(ViewerLayout.entranceLevel.rawValue < NSWindow.Level.screenSaver.rawValue, "below lock screen")
    for corner in OrbCorner.allCases {
        try check(screen.contains(corner.rectangle(size: NSSize(width: edge, height: edge), within: screen)),
                  "corner bounds")
    }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("peeklet-self-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("synthetic-source.jpg")
    let invalid = root.appendingPathComponent("not-an-image.txt")
    let color = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: 48, height: 32, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: color,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw TestFailure.failed("synthetic bitmap context")
    }
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
    guard let synthetic = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(original as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw TestFailure.failed("synthetic JPEG creation")
    }
    let metadata: [String: Any] = [
        kCGImagePropertyGPSDictionary as String: [
            kCGImagePropertyGPSLatitude as String: 40.0,
            kCGImagePropertyGPSLatitudeRef as String: "N",
            kCGImagePropertyGPSLongitude as String: 70.0,
            kCGImagePropertyGPSLongitudeRef as String: "W"
        ],
        kCGImagePropertyExifDictionary as String: [
            kCGImagePropertyExifUserComment as String: "synthetic-original-marker"
        ],
        kCGImagePropertyOrientation as String: 1
    ]
    CGImageDestinationAddImage(output, synthetic, metadata as CFDictionary)
    guard CGImageDestinationFinalize(output) else { throw TestFailure.failed("synthetic JPEG write") }
    try Data("not an image".utf8).write(to: invalid)
    let originalBytes = try Data(contentsOf: original)
    let directory = root.appendingPathComponent("library", isDirectory: true)
    let library = try PhotoLibrary(directory: directory)
    try check(library.count == 0 && library.ids.isEmpty, "empty library")
    try library.importPhotos(from: [original])
    try check(library.count == 1, "import")
    let importedID = library.ids[0]
    let reloaded = try PhotoLibrary(directory: directory)
    try check(reloaded.ids == [importedID], "reload")
    let image = try reloaded.image(at: 0)
    try check(image.isValid && image.size.width > 0 && image.size.height > 0, "decode copy")
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let manifest = try String(contentsOf: manifestURL, encoding: .utf8)
    try check(!manifest.contains(original.lastPathComponent) && !manifest.contains(original.path), "no source filename or path")
    let importedURL = directory.appendingPathComponent(importedID.uuidString.lowercased() + ".png")
    guard let source = CGImageSourceCreateWithURL(importedURL as CFURL, nil),
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
        throw TestFailure.failed("decode imported PNG properties")
    }
    try check(properties[kCGImagePropertyGPSDictionary as String] == nil, "GPS removed")
    let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    try check(exif[kCGImagePropertyExifUserComment as String] == nil, "source EXIF comment removed")
    try expectFailure("invalid input rejected") { try reloaded.importPhotos(from: [invalid]) }
    try check(reloaded.count == 1 && reloaded.ids == [importedID], "invalid import leaves library unchanged")
    try expectFailure("mixed batch is atomic") { try reloaded.importPhotos(from: [original, invalid]) }
    try check(reloaded.count == 1 && reloaded.ids == [importedID], "failed batch has no partial import")
    try reloaded.importPhotos(from: Array(repeating: original, count: 29))
    try check(reloaded.count == 30 && Set(reloaded.ids).count == 30, "capacity and unique identifiers")
    try expectFailure("capacity enforced") { try reloaded.importPhotos(from: [original]) }
    try check(reloaded.count == 30, "capacity failure preserves library")
    try reloaded.remove(at: 0)
    try check(reloaded.count == 29 && !FileManager.default.fileExists(atPath: importedURL.path), "remove one copy")
    try reloaded.removeAll()
    let emptyReload = try PhotoLibrary(directory: directory)
    try check(reloaded.count == 0 && emptyReload.count == 0, "remove all and reload")
    let remainingOriginal = try Data(contentsOf: original)
    try check(remainingOriginal == originalBytes, "original image remains unchanged")

    // Simulate interrupted transactions entirely within the synthetic library.
    let journal = directory.appendingPathComponent(".transaction.json")
    let abandonedID = UUID()
    let abandoned = directory.appendingPathComponent(abandonedID.uuidString.lowercased() + ".png")
    try Data("partial".utf8).write(to: abandoned)
    try Data("{\"version\":1,\"operation\":\"importing\",\"ids\":[\"\(abandonedID.uuidString)\"]}".utf8).write(to: journal)
    let importRecovered = try PhotoLibrary(directory: directory)
    try check(importRecovered.count == 0 && !FileManager.default.fileExists(atPath: abandoned.path),
              "interrupted import rolls back")
    try importRecovered.importPhotos(from: [original])
    let removalID = importRecovered.ids[0]
    let removalSource = directory.appendingPathComponent(removalID.uuidString.lowercased() + ".png")
    let pending = directory.appendingPathComponent(".pending-delete-" + removalID.uuidString.lowercased() + ".png")
    try Data("{\"version\":1,\"operation\":\"removing\",\"ids\":[\"\(removalID.uuidString)\"]}".utf8).write(to: journal)
    try FileManager.default.moveItem(at: removalSource, to: pending)
    let removalRecovered = try PhotoLibrary(directory: directory)
    try check(removalRecovered.ids == [removalID] && FileManager.default.fileExists(atPath: removalSource.path),
              "uncommitted removal restored")
    try Data("{\"version\":1,\"operation\":\"removing\",\"ids\":[\"\(removalID.uuidString)\"]}".utf8).write(to: journal)
    try FileManager.default.moveItem(at: removalSource, to: pending)
    try Data("{\"version\":1,\"ids\":[]}".utf8).write(to: manifestURL)
    let removalCompleted = try PhotoLibrary(directory: directory)
    try check(removalCompleted.count == 0 && !FileManager.default.fileExists(atPath: pending.path),
              "committed removal finishes")
    let link = root.appendingPathComponent("synthetic-link.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    try expectFailure("symlink input rejected") { try removalCompleted.importPhotos(from: [link]) }
    try check(removalCompleted.count == 0, "symlink rejection leaves library unchanged")

    let corruptDirectory = root.appendingPathComponent("corrupt-library", isDirectory: true)
    try FileManager.default.createDirectory(at: corruptDirectory, withIntermediateDirectories: false)
    let corrupt = corruptDirectory.appendingPathComponent("manifest.json")
    let corruptBytes = Data("{invalid".utf8)
    try corruptBytes.write(to: corrupt)
    try expectFailure("corrupt manifest rejected") { _ = try PhotoLibrary(directory: corruptDirectory) }
    let remainingCorrupt = try Data(contentsOf: corrupt)
    try check(remainingCorrupt == corruptBytes, "corrupt manifest remains unchanged")

    if ProcessInfo.processInfo.environment["PEEKLET_GUI_TESTS"] == "1" {
        _ = NSApplication.shared
        let panel = PassivePanel(rectangle: NSRect(x: 0, y: 0, width: edge, height: edge), level: .floating)
        try check(!panel.canBecomeKey && !panel.canBecomeMain, "nonactivating panel")
        try check(panel.styleMask.contains(.nonactivatingPanel), "nonactivating style")
        try check(panel.collectionBehavior.contains(.canJoinAllSpaces), "all spaces")
        try check(panel.collectionBehavior.contains(.fullScreenAuxiliary), "fullscreen auxiliary")
        try check(!panel.isVisible, "test panel never displayed")
    }
    print("PASS: \(checks) checks using synthetic images; no photos displayed.")
}
