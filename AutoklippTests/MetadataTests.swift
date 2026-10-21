import Foundation
import Testing

@testable import Autoklipp

@Suite("Metadata")
struct MetadataTests {
    @Test func imageCaptureDateAndSizeComeFromExif() throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "photo.jpg")
        try TestMedia.writeImage(to: url, width: 640, height: 480, color: TestMedia.RGB.palette[0], date: TestMedia.baseDate)
        let info = try MediaMetadataReader.readImage(at: url)
        #expect(info.width == 640)
        #expect(info.height == 480)
        #expect(info.date == TestMedia.baseDate)
    }

    @Test func videoCreationDateAndDuration() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "clip.mov")
        try await TestMedia.writeVideo(to: url, duration: 2, width: 320, height: 180, color: TestMedia.RGB.palette[1], date: TestMedia.baseDate)
        let info = try await MediaMetadataReader.readVideo(at: url)
        #expect(abs(info.duration - 2) < 0.1)
        #expect(info.width == 320 && info.height == 180)
        #expect(info.date == TestMedia.baseDate)
        #expect(!info.hasAudio)
    }

    @Test func brokenFilesAreRejected() async throws {
        let folder = try TestMedia.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "broken.mov")
        try Data("not a movie".utf8).write(to: url)
        await #expect(throws: (any Error).self) { try await MediaMetadataReader.readVideo(at: url) }
        let image = folder.appending(path: "broken.jpg")
        try Data("not an image".utf8).write(to: image)
        #expect(throws: (any Error).self) { try MediaMetadataReader.readImage(at: image) }
    }

    /// Two items load at once: both count towards the bar, and an update that arrives after its
    /// item has finished does not count it twice.
    @Test @MainActor func importProgressAddsUpParallelLoads() {
        let progress = ImportProgress()
        progress.start(total: 4)
        progress.report(0.5, for: 0)
        progress.report(0.5, for: 1)
        #expect(abs(progress.fraction - 0.25) < 1e-9)
        progress.finish(0)
        progress.report(1, for: 0)
        #expect(progress.finished == 1)
        #expect(abs(progress.fraction - 0.375) < 1e-9)
        progress.finish(1)
        #expect(abs(progress.fraction - 0.5) < 1e-9)
    }

    @Test func exifDatesHonourTheirOffset() {
        let date = MediaMetadataReader.exifDate("2026:07:14 18:00:00", offset: "+02:00")
        #expect(date == ISO8601DateFormatter().date(from: "2026-07-14T16:00:00Z"))
    }

    @Test func iso6709Locations() {
        let point = MediaMetadataReader.iso6709("+59.3293+018.0686+012.345/")
        #expect(point?.latitude == 59.3293)
        #expect(point?.longitude == 18.0686)
        #expect(MediaMetadataReader.iso6709("-33.8688+151.2093/")?.latitude == -33.8688)
        #expect(MediaMetadataReader.iso6709("garbage") == nil)
    }
}

@Suite("Localisation")
struct LocalisationTests {
    @Test func swedishIsBundled() throws {
        let path = try #require(Bundle.main.path(forResource: "sv", ofType: "lproj"))
        let swedish = try #require(Bundle(path: path))
        #expect(swedish.localizedString(forKey: "Next", value: nil, table: nil) == "Nästa")
        #expect(swedish.localizedString(forKey: "Analysing clips…", value: nil, table: nil) == "Analyserar klipp…")
    }

    @Test func formattingIsLocalised() {
        #expect(Formatting.clock(75) == "1:15")
        #expect(!Formatting.duration(75).isEmpty)
    }
}
