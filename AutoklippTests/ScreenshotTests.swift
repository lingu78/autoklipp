import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// Screenshots of the start screen for review. Runs only when AUTOKLIPP_SCREENSHOTS names a
/// folder (CI uploads it as an artifact); a small JPEG copy also goes to the log as base64 lines
/// starting with SCREENSHOT:, since artifacts are not always reachable.
@Suite("Screenshots", .serialized)
@MainActor
struct ScreenshotTests {
    @Test func startScreen() async throws {
        guard let path = ProcessInfo.processInfo.environment["AUTOKLIPP_SCREENSHOTS"], !path.isEmpty else { return }
        let folder = URL(filePath: path, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            Issue.record("no window scene")
            return
        }

        let model = AppModel(inMemory: true)
        let context = model.container.mainContext
        let samples: [(String, Double, Double, Self.Look)] = [
            ("Midsommar i Dalarna", 62, -3_600 * 5, .sunset),
            ("Sommarlov vid havet", 95, -3_600 * 30, .sea),
            ("Fjällvandring", 184, -3_600 * 24 * 9, .mountains),
        ]
        for (title, duration, age, look) in samples {
            let project = SavedProject(id: UUID(), title: title, duration: duration, payload: Data())
            project.updatedAt = Date().addingTimeInterval(age)
            project.thumbnail = Self.thumbnail(look).jpegData(compressionQuality: 0.85)
            context.insert(project)
        }
        try context.save()

        let screen = scene.screen.bounds.size
        let shots: [(String, UIUserInterfaceStyle, CGSize)] = [
            ("home-light", .light, screen),
            ("home-dark", .dark, screen),
            ("home-full", .light, CGSize(width: screen.width, height: 1_500)),
        ]
        for (name, style, size) in shots {
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(
                rootView: NavigationStack { HomeView() }
                    .environment(model)
                    .modelContainer(model.container)
            )
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(2))

            let full = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try #require(full.pngData()).write(to: folder.appending(path: "\(name).png"))

            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let small = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            Self.log(name: name, jpeg: try #require(small.jpegData(compressionQuality: 0.6)))
            window.isHidden = true
        }
    }

    enum Look {
        case sunset, sea, mountains
    }

    /// A small painted landscape standing in for a film's first frame.
    static func thumbnail(_ look: Look) -> UIImage {
        let size = CGSize(width: 300, height: 380)
        return UIGraphicsImageRenderer(size: size).image { context in
            let cg = context.cgContext
            let (sky, ground): ([UIColor], UIColor) = switch look {
            case .sunset: ([UIColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1), UIColor(red: 0.85, green: 0.30, blue: 0.45, alpha: 1)],
                           UIColor(red: 0.20, green: 0.35, blue: 0.22, alpha: 1))
            case .sea: ([UIColor(red: 0.45, green: 0.75, blue: 0.95, alpha: 1), UIColor(red: 0.80, green: 0.92, blue: 0.98, alpha: 1)],
                        UIColor(red: 0.10, green: 0.45, blue: 0.70, alpha: 1))
            case .mountains: ([UIColor(red: 0.55, green: 0.70, blue: 0.90, alpha: 1), UIColor(red: 0.90, green: 0.93, blue: 0.97, alpha: 1)],
                              UIColor(red: 0.35, green: 0.40, blue: 0.48, alpha: 1))
            }
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky.map(\.cgColor) as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.7), options: [])
            UIColor.white.withAlphaComponent(0.85).setFill()
            cg.fillEllipse(in: CGRect(x: size.width * 0.6, y: size.height * 0.18, width: 70, height: 70))
            ground.setFill()
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 0, y: size.height))
            switch look {
            case .mountains:
                path.addLine(to: CGPoint(x: 0, y: size.height * 0.62))
                path.addLine(to: CGPoint(x: size.width * 0.35, y: size.height * 0.35))
                path.addLine(to: CGPoint(x: size.width * 0.6, y: size.height * 0.55))
                path.addLine(to: CGPoint(x: size.width * 0.8, y: size.height * 0.42))
                path.addLine(to: CGPoint(x: size.width, y: size.height * 0.6))
            default:
                path.addLine(to: CGPoint(x: 0, y: size.height * 0.68))
                path.addQuadCurve(to: CGPoint(x: size.width, y: size.height * 0.64), controlPoint: CGPoint(x: size.width * 0.5, y: size.height * 0.58))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.close()
            path.fill()
        }
    }

    static func log(name: String, jpeg: Data) {
        let text = Array(jpeg.base64EncodedString().utf8)
        for (index, start) in stride(from: 0, to: text.count, by: 3_000).enumerated() {
            let chunk = String(decoding: text[start..<min(text.count, start + 3_000)], as: UTF8.self)
            print("SCREENSHOT:\(name):\(index):\(chunk)")
        }
    }
}
