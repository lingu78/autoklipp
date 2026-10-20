import ClipCore
import Foundation

/// A picked item that has been copied into the project, with its metadata.
struct ImportedMedia: Identifiable, Hashable, Sendable {
    var item: MediaItem
    var url: URL

    var id: String { item.id }
}
