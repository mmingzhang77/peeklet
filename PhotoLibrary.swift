import AppKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Errors intentionally omit file names and underlying system error descriptions.
enum PhotoLibraryError: LocalizedError {
    case invalidImage
    case imageTooLarge
    case capacityExceeded
    case invalidLibrary
    case invalidIndex
    case storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "One or more selected files could not be read as a supported image."
        case .imageTooLarge: return "One or more selected images exceed the size limit."
        case .capacityExceeded: return "The library can hold up to 30 photos."
        case .invalidLibrary: return "The photo library could not be read safely."
        case .invalidIndex: return "The selected photo is no longer available."
        case .storageUnavailable: return "The photo library could not be updated."
        }
    }
}

/// Stores only resized, metadata-stripped copies under the app's own directory.
/// A journal makes interrupted imports and removals recoverable without ever
/// referencing or modifying the source files.
final class PhotoLibrary {
    private struct Manifest: Codable {
        let version: Int
        let ids: [UUID]
    }

    private struct Journal: Codable {
        enum Operation: String, Codable { case importing, removing }
        let version: Int
        let operation: Operation
        let ids: [UUID]
    }

    private static let maximumCount = 30
    private static let maximumInputBytes = 50 * 1024 * 1024
    private static let maximumPixels: Int64 = 100_000_000
    private static let maximumDimension = 2048
    private static let maximumJSONBytes = 16 * 1024
    private static let supportedTypes: Set<String> = [
        UTType.jpeg.identifier, UTType.png.identifier, UTType.tiff.identifier,
        UTType.heic.identifier, UTType.heif.identifier
    ]

    private let directory: URL
    private let fm = FileManager.default
    private(set) var ids: [UUID] = []
    var count: Int { ids.count }

    private var manifestURL: URL { directory.appendingPathComponent("manifest.json") }
    private var journalURL: URL { directory.appendingPathComponent(".transaction.json") }
    private var lockURL: URL { directory.appendingPathComponent(".lock") }
    private func photoURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString.lowercased() + ".png")
    }
    private func pendingURL(_ id: UUID) -> URL {
        directory.appendingPathComponent(".pending-delete-" + id.uuidString.lowercased() + ".png")
    }

    init(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        do {
            try prepareDirectory()
            try withLock {
                var current = try readManifest()
                try recover(current: &current)
                try validateFiles(current)
                ids = current
            }
        } catch let error as PhotoLibraryError { throw error }
        catch { throw PhotoLibraryError.storageUnavailable }
    }

    static func openDefault() throws -> PhotoLibrary {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                       in: .userDomainMask).first else {
            throw PhotoLibraryError.storageUnavailable
        }
        return try PhotoLibrary(directory: support.appendingPathComponent("Peeklet", isDirectory: true))
    }

    func importPhotos(from urls: [URL]) throws {
        try synchronized {
            guard !urls.isEmpty else { return }
            guard urls.count <= Self.maximumCount - ids.count else {
                throw PhotoLibraryError.capacityExceeded
            }
            let newIDs = urls.map { _ in UUID() }
            guard Set(newIDs).count == newIDs.count else { throw PhotoLibraryError.storageUnavailable }
            for id in newIDs {
                guard try entry(photoURL(id)) == nil, try entry(pendingURL(id)) == nil else {
                    throw PhotoLibraryError.storageUnavailable
                }
            }
            try writeJournal(Journal(version: 1, operation: .importing, ids: newIDs))
            do {
                for (url, id) in zip(urls, newIDs) {
                    let encoded = try autoreleasepool { try Self.sanitizedPNG(from: url) }
                    try writePrivate(encoded, to: photoURL(id))
                }
                let updated = ids + newIDs
                try writeManifest(updated)
                ids = updated
                try removeRegularIfPresent(journalURL)
            } catch {
                try rollbackAfterFailure()
                throw error
            }
        }
    }

    func image(at index: Int) throws -> NSImage {
        try synchronized {
            guard ids.indices.contains(index) else { throw PhotoLibraryError.invalidIndex }
            let url = photoURL(ids[index])
            guard let info = try entry(url), isRegular(info), info.st_size > 0,
                  info.st_size <= Self.maximumInputBytes else {
                throw PhotoLibraryError.invalidLibrary
            }
            let data = try readPrivate(url, maxBytes: Self.maximumInputBytes)
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetStatus(source) == .statusComplete,
                  (CGImageSourceGetType(source) as String?) == UTType.png.identifier,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0,
                  width <= Self.maximumDimension, height <= Self.maximumDimension,
                  let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                throw PhotoLibraryError.invalidLibrary
            }
            return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
        }
    }

    func remove(at index: Int) throws {
        try synchronized {
            guard ids.indices.contains(index) else { throw PhotoLibraryError.invalidIndex }
            try removeIDs([ids[index]])
        }
    }

    func removeAll() throws {
        try synchronized {
            guard !ids.isEmpty else { return }
            try removeIDs(ids)
        }
    }

    private func removeIDs(_ removed: [UUID]) throws {
        for id in removed {
            guard let original = try entry(photoURL(id)), isRegular(original),
                  try entry(pendingURL(id)) == nil else { throw PhotoLibraryError.invalidLibrary }
        }
        try writeJournal(Journal(version: 1, operation: .removing, ids: removed))
        do {
            for id in removed { try fm.moveItem(at: photoURL(id), to: pendingURL(id)) }
            let removedSet = Set(removed)
            let updated = ids.filter { !removedSet.contains($0) }
            try writeManifest(updated)
            ids = updated
            for id in removed { try removeRegularIfPresent(pendingURL(id)) }
            try removeRegularIfPresent(journalURL)
        } catch {
            try rollbackAfterFailure()
            throw error
        }
    }

    /// Reload while holding a per-library process lock, so concurrent instances
    /// cannot overwrite one another's manifest updates.
    private func synchronized<T>(_ body: () throws -> T) throws -> T {
        do {
            return try withLock {
                var current = try readManifest()
                try recover(current: &current)
                try validateFiles(current)
                ids = current
                return try body()
            }
        } catch let error as PhotoLibraryError { throw error }
        catch { throw PhotoLibraryError.storageUnavailable }
    }

    private func rollbackAfterFailure() throws {
        var current = try readManifest()
        try recover(current: &current)
        ids = current
    }

    /// Manifest membership is the transaction commit marker. Before a commit,
    /// import copies are removed and staged removals are restored. After a
    /// commit, removal staging is cleaned up. No recovery deletes source files.
    private func recover(current: inout [UUID]) throws {
        guard try entry(journalURL) != nil else { return }
        let data = try readPrivate(journalURL, maxBytes: Self.maximumJSONBytes)
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.version == 1, !journal.ids.isEmpty,
              journal.ids.count <= Self.maximumCount,
              Set(journal.ids).count == journal.ids.count else {
            throw PhotoLibraryError.invalidLibrary
        }
        let members = Set(current)
        let present = journal.ids.filter { members.contains($0) }.count
        guard present == 0 || present == journal.ids.count else { throw PhotoLibraryError.invalidLibrary }
        switch journal.operation {
        case .importing:
            if present == 0 {
                for id in journal.ids { try removeRegularIfPresent(photoURL(id)) }
            } else {
                try validateFiles(journal.ids)
            }
        case .removing:
            for id in journal.ids {
                let original = try entry(photoURL(id))
                let pending = try entry(pendingURL(id))
                if let original = original, !isRegular(original) { throw PhotoLibraryError.invalidLibrary }
                if let pending = pending, !isRegular(pending) { throw PhotoLibraryError.invalidLibrary }
                if present == journal.ids.count {
                    guard !(original != nil && pending != nil), original != nil || pending != nil else {
                        throw PhotoLibraryError.invalidLibrary
                    }
                    if pending != nil { try fm.moveItem(at: pendingURL(id), to: photoURL(id)) }
                } else {
                    guard original == nil else { throw PhotoLibraryError.invalidLibrary }
                    if pending != nil { try fm.removeItem(at: pendingURL(id)) }
                }
            }
        }
        try removeRegularIfPresent(journalURL)
        current = try readManifest()
    }

    private func readManifest() throws -> [UUID] {
        guard try entry(manifestURL) != nil else { return [] }
        let data = try readPrivate(manifestURL, maxBytes: Self.maximumJSONBytes)
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.version == 1, manifest.ids.count <= Self.maximumCount,
              Set(manifest.ids).count == manifest.ids.count else { throw PhotoLibraryError.invalidLibrary }
        return manifest.ids
    }

    private func writeManifest(_ updated: [UUID]) throws {
        try writePrivate(JSONEncoder().encode(Manifest(version: 1, ids: updated)), to: manifestURL)
    }

    private func writeJournal(_ journal: Journal) throws {
        guard try entry(journalURL) == nil else { throw PhotoLibraryError.invalidLibrary }
        try writePrivate(JSONEncoder().encode(journal), to: journalURL)
    }

    private func validateFiles(_ values: [UUID]) throws {
        for id in values {
            guard let info = try entry(photoURL(id)), isRegular(info), info.st_size > 0 else {
                throw PhotoLibraryError.invalidLibrary
            }
        }
    }

    private func prepareDirectory() throws {
        if let info = try entry(directory) {
            guard (info.st_mode & S_IFMT) == S_IFDIR else { throw PhotoLibraryError.invalidLibrary }
        } else {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        let fd = lockURL.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return Darwin.open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard fd >= 0 else { throw PhotoLibraryError.storageUnavailable }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, isRegular(info), fchmod(fd, mode_t(0o600)) == 0,
              flock(fd, LOCK_EX) == 0 else { throw PhotoLibraryError.storageUnavailable }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    /// lstat checks the entry itself, never following a symlink on deletion.
    private func entry(_ url: URL) throws -> stat? {
        var info = stat()
        let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return lstat(path, &info)
        }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw PhotoLibraryError.storageUnavailable
    }

    private func isRegular(_ info: stat) -> Bool { (info.st_mode & S_IFMT) == S_IFREG }

    private func readPrivate(_ url: URL, maxBytes: Int) throws -> Data {
        return try Self.readRegularFile(url, maxBytes: maxBytes,
                                        invalid: .invalidLibrary, tooLarge: .invalidLibrary)
    }

    private func writePrivate(_ data: Data, to url: URL) throws {
        if let existing = try entry(url), !isRegular(existing) { throw PhotoLibraryError.invalidLibrary }
        try data.write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func removeRegularIfPresent(_ url: URL) throws {
        guard let info = try entry(url) else { return }
        guard isRegular(info) else { throw PhotoLibraryError.invalidLibrary }
        try fm.removeItem(at: url)
    }

    private static func sanitizedPNG(from url: URL) throws -> Data {
        let input = try readRegularFile(url, maxBytes: maximumInputBytes,
                                        invalid: .invalidImage, tooLarge: .imageTooLarge)
        guard !input.isEmpty else { throw PhotoLibraryError.invalidImage }
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(input as CFData, sourceOptions),
              CGImageSourceGetStatus(source) == .statusComplete,
              let type = CGImageSourceGetType(source) as String?, supportedTypes.contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.int64Value,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.int64Value,
              width > 0, height > 0 else { throw PhotoLibraryError.invalidImage }
        guard height <= maximumPixels, width <= maximumPixels / height else {
            throw PhotoLibraryError.imageTooLarge
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
            kCGImageSourceShouldCacheImmediately: false
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw PhotoLibraryError.invalidImage
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output as CFMutableData,
                                                                  UTType.png.identifier as CFString, 1, nil) else {
            throw PhotoLibraryError.storageUnavailable
        }
        // Supply a newly decoded image and no source properties: source EXIF,
        // IPTC, GPS, timestamps and file names are not copied into the PNG.
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else { throw PhotoLibraryError.storageUnavailable }
        return output as Data
    }

    /// Open once with no-follow and fstat the descriptor. This avoids following
    /// a swapped symlink between a path check and reading the selected file.
    private static func readRegularFile(_ url: URL, maxBytes: Int,
                                        invalid: PhotoLibraryError,
                                        tooLarge: PhotoLibraryError) throws -> Data {
        let fd = url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path = path else { return -1 }
            return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else { throw invalid }
        defer { _ = Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size >= 0 else { throw invalid }
        guard info.st_size <= maxBytes else { throw tooLarge }
        var result = Data(capacity: Int(info.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(fd, bytes.baseAddress, bytes.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw invalid
            }
            if bytesRead == 0 { break }
            guard bytesRead <= maxBytes - result.count else { throw tooLarge }
            result.append(contentsOf: buffer.prefix(bytesRead))
        }
        return result
    }
}
