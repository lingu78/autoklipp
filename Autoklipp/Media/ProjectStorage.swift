import Foundation

/// Where a project's copied media and exports live on disk.
///
/// Media picked with PhotosPicker are copied into the app's sandbox, because the app has no
/// library access to read them again later.
struct ProjectStorage: Sendable {
    let projectID: UUID

    static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Projects", directoryHint: .isDirectory)
    }

    var directory: URL {
        Self.root.appending(path: projectID.uuidString, directoryHint: .isDirectory)
    }

    var mediaDirectory: URL {
        directory.appending(path: "Media", directoryHint: .isDirectory)
    }

    var exportDirectory: URL {
        URL.temporaryDirectory.appending(path: "Exports", directoryHint: .isDirectory)
    }

    func prepare() throws {
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }
}
