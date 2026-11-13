import ClipCore
import SwiftData
import SwiftUI
import Testing
import UIKit

@testable import Autoklipp

/// The App Store's product page images, made from the app's own screens: the header (21:9,
/// 3840 × 1646), the search results image (3:2, 3840 × 2560), iPhone screenshots for the 6.9"
/// display (1320 × 2868) and the 6.3" one (1206 × 2622), and iPhone Duo's outer (1398 × 2034) and
/// inner (2853 × 2007) displays. A film is made from painted landscapes, so that the screens show
/// something worth looking at. Runs in CI when AUTOKLIPP_STORE_ASSETS is set; the files go to the
/// screenshots folder under store/ and to the log as base64 lines, like the other screenshots.
@Suite("App Store images", .serialized)
@MainActor
struct StoreAssetsTests {
    /// The iPhone 6.9" display in points; drawn at 3x, its screenshots are 1320 × 2868.
    static let phone = CGSize(width: 440, height: 956)
    /// Swedish images, for the Swedish product page (the app's primary language in App Store
    /// Connect): CI runs these tests again with the app in Swedish and AUTOKLIPP_STORE_LANGUAGE=sv;
    /// the files then go to store/sv/ and the log lines start with store-sv-.
    static let swedish = ProcessInfo.processInfo.environment["AUTOKLIPP_STORE_LANGUAGE"] == "sv"

    /// The English or the Swedish text, by the language the images are made in.
    static func text(_ english: String, _ swedish: String) -> String {
        Self.swedish ? swedish : english
    }
    /// iPhone Duo's outer display in points, 1398 × 2034 at 3x, and its inner display unfolded,
    /// 2853 × 2007 at 3x: the screenshot sizes App Store Connect takes for iPhone Duo.
    static let duoOuter = CGSize(width: 466, height: 678)
    static let duoInner = CGSize(width: 951, height: 669)

    /// Screenshots for iPhone Duo: the phone's layout on the outer display and the two columns
    /// on the inner one, each as a slide of the display's own size.
    @Test(.timeLimit(.minutes(10)))
    func duoImages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AUTOKLIPP_STORE_ASSETS"] != nil,
              let path = environment["AUTOKLIPP_SCREENSHOTS"], !path.isEmpty else { return }
        let folder = URL(filePath: path, directoryHint: .isDirectory).appending(path: Self.swedish ? "store/sv" : "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        let model = try await Self.modelWithFilm()
        let storage = model.draft.storage
        defer { storage.removeAll() }

        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: RootView()
                .environment(model)
                .modelContainer(model.container)
        )
        func fold(to size: CGSize, unfolded: Bool) {
            window.traitOverrides.horizontalSizeClass = unfolded ? .regular : .compact
            window.traitOverrides.verticalSizeClass = .regular
            window.frame = CGRect(origin: .zero, size: size)
            window.layoutIfNeeded()
        }
        fold(to: Self.duoOuter, unfolded: false)
        window.makeKeyAndVisible()
        defer {
            model.preview?.pause()
            model.closePreview()
            window.isHidden = true
            window.rootViewController = nil
        }
        func screen(_ path: [Route], wait: Double = 2) async throws -> UIImage {
            model.path = path
            try await Task.sleep(for: .seconds(wait))
            return Self.draw(window)
        }
        let film: [Route] = [.media, .length, .style, .preview]

        // Folded: the outer display, with the phone's layout.
        let outerHome = try await screen([])
        let outerStyle = try await screen([.media, .length, .style])
        model.path = film
        try await Task.sleep(for: .seconds(1))
        model.preview?.play()
        // Long enough for every thumbnail in the clip strip.
        let outerFilm = try await screen(film, wait: 6)
        model.preview?.pause()

        // Unfolded: the inner display, the film beside the steps.
        fold(to: Self.duoInner, unfolded: true)
        model.preview?.play()
        let innerFilm = try await screen(film, wait: 4)
        model.preview?.pause()
        let innerStyle = try await screen([.media, .length, .style], wait: 3)
        model.path = film
        try await Task.sleep(for: .seconds(1))
        model.show(.export)
        try await Task.sleep(for: .seconds(2))
        let innerExport = Self.draw(window)
        model.closeExport()
        try await Task.sleep(for: .seconds(1))
        let innerHome = try await screen([], wait: 3)

        let outer = CGSize(width: 1398, height: 2034)
        let inner = CGSize(width: 2853, height: 2007)
        let slides: [(String, CGSize, CGFloat, String, String, UIImage)] = [
            ("duo-outer-1-film", outer, 860, Self.text("Your photos, cut to the beat", "Dina bilder, klippta i takt"),
             Self.text("A finished film with music and transitions.", "En färdig film med musik och övergångar."), outerFilm),
            ("duo-outer-2-style", outer, 860, Self.text("Pick a style and a song", "Välj stil och låt"),
             Self.text("Five styles, with music made for each.", "Fem stilar, med musik gjord för varje."), outerStyle),
            ("duo-outer-3-home", outer, 860, Self.text("All on your iPhone", "Allt på din iPhone"),
             Self.text("Nothing is uploaded, and there is no account.", "Inget laddas upp, och du behöver inget konto."), outerHome),
            ("duo-inner-1-film", inner, 1560, Self.text("Bigger when unfolded", "Större när den fälls ut"),
             Self.text("The film beside every step, on the inner display.", "Filmen bredvid varje steg, på innerskärmen."), innerFilm),
            ("duo-inner-2-style", inner, 1560, Self.text("Pick a style and a song", "Välj stil och låt"),
             Self.text("Calm, Energetic, Nostalgic, Travel or Cinematic.", "Lugn, Energisk, Nostalgisk, Resa eller Filmisk."), innerStyle),
            ("duo-inner-3-export", inner, 1560, Self.text("Save in 4K or share", "Spara i 4K eller dela"),
             Self.text("Portrait, landscape or square.", "Stående, liggande eller kvadrat."), innerExport),
            ("duo-inner-4-home", inner, 1560, Self.text("All on your iPhone", "Allt på din iPhone"),
             Self.text("Nothing is uploaded, and there is no account.", "Inget laddas upp, och du behöver inget konto."), innerHome),
        ]
        for (name, size, screenWidth, caption, detail, image) in slides {
            let slide = try Self.render(
                StoreSlide(caption: caption, detail: detail, screen: image, size: size, screenWidth: screenWidth), size: size
            )
            try Self.save(slide, name: name, folder: folder)
        }
    }

    @Test(.timeLimit(.minutes(10)))
    func productPageImages() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AUTOKLIPP_STORE_ASSETS"] != nil,
              let path = environment["AUTOKLIPP_SCREENSHOTS"], !path.isEmpty else { return }
        let folder = URL(filePath: path, directoryHint: .isDirectory).appending(path: Self.swedish ? "store/sv" : "store", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)

        let model = try await Self.modelWithFilm()
        let storage = model.draft.storage
        defer { storage.removeAll() }

        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: Self.phone)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = UIHostingController(
            rootView: RootView()
                .environment(model)
                .modelContainer(model.container)
        )
        window.makeKeyAndVisible()
        defer {
            model.preview?.pause()
            model.closePreview()
            window.isHidden = true
            window.rootViewController = nil
        }

        func screen(_ path: [Route], wait: Double = 2) async throws -> UIImage {
            model.path = path
            try await Task.sleep(for: .seconds(wait))
            return Self.draw(window)
        }
        let home = try await screen([])
        let length = try await screen([.media, .length])
        let style = try await screen([.media, .length, .style])
        model.path = [.media, .length, .style, .preview]
        try await Task.sleep(for: .seconds(1))
        model.preview?.play()
        // Long enough for every thumbnail in the clip strip; videos' take a moment on a busy runner.
        let preview = try await screen([.media, .length, .style, .preview], wait: 6)
        model.preview?.pause()
        model.show(.export)
        try await Task.sleep(for: .seconds(2))
        let export = Self.draw(window)
        model.closeExport()
        try await Task.sleep(for: .seconds(1))
        model.draft.analyses = [:]
        model.createFilm(newVersion: true)
        try await Task.sleep(for: .milliseconds(900))
        let making = Self.draw(window)
        var waited = 0
        while model.generation != nil, waited < 600 {
            try await Task.sleep(for: .milliseconds(200))
            waited += 1
        }

        // The screenshots, with a caption over each.
        let slides: [(String, String, String, UIImage)] = [
            ("1-film", Self.text("Your photos, cut to the beat", "Dina bilder, klippta i takt"),
             Self.text("A finished film with music and transitions, made on your iPhone.", "En färdig film med musik och övergångar, gjord på din iPhone."), preview),
            ("2-style", Self.text("Pick a style and a song", "Välj stil och låt"),
             Self.text("Calm, Energetic, Nostalgic, Travel or Cinematic – with music made for each.", "Lugn, Energisk, Nostalgisk, Resa eller Filmisk – med musik gjord för varje."), style),
            ("3-length", Self.text("Any length you like", "Precis så lång du vill"),
             Self.text("From 15 seconds to 10 minutes.", "Från 15 sekunder till 10 minuter."), length),
            ("4-making", Self.text("The best moments, picked for you", "De bästa stunderna, valda åt dig"),
             Self.text("Sharp shots, faces and steady video, on the beat.", "Skarpa bilder, ansikten och stadig video, i takt."), making),
            ("5-export", Self.text("Save in 4K or share", "Spara i 4K eller dela"),
             Self.text("Portrait, landscape or square.", "Stående, liggande eller kvadrat."), export),
            ("6-home", Self.text("All on your iPhone", "Allt på din iPhone"),
             Self.text("Nothing is uploaded, and there is no account.", "Inget laddas upp, och du behöver inget konto."), home),
        ]
        // The 6.9" display, and the 6.3" one App Store Connect requires (iPhone 17, 1206 × 2622),
        // drawn at its own size rather than left to App Store Connect's scaling.
        let medium = CGSize(width: 1206, height: 2622)
        for (name, caption, detail, image) in slides {
            let slide = try Self.render(StoreSlide(caption: caption, detail: detail, screen: image), size: CGSize(width: 1320, height: 2868))
            try Self.save(slide, name: "iphone-69-\(name)", folder: folder)
            let smaller = try Self.render(
                StoreSlide(caption: caption, detail: detail, screen: image, size: medium, screenWidth: 960 * medium.width / 1320), size: medium
            )
            try Self.save(smaller, name: "iphone-63-\(name)", folder: folder)
        }
        let header = try Self.render(StoreHeader(screens: [style, preview, length]), size: CGSize(width: 3840, height: 1646))
        try Self.save(header, name: "header", folder: folder, png: true)
        let search = try Self.render(StoreSearchResults(screens: [style, preview, export]), size: CGSize(width: 3840, height: 2560))
        try Self.save(search, name: "search-results", folder: folder, png: true)
    }

    // MARK: The film

    /// A project of painted landscapes with a 30 s film of them in the preview, and three saved
    /// films for the start screen.
    static func modelWithFilm() async throws -> AppModel {
        let model = AppModel(inMemory: true)
        try model.draft.storage.prepare()
        let start = Date(timeIntervalSince1970: 1_782_000_000)
        var media: [ImportedMedia] = []
        for (index, landscape) in Landscape.all.enumerated() {
            let url = model.draft.storage.mediaDirectory.appending(path: "landscape-\(index).jpg")
            try #require(landscape.image(size: CGSize(width: 1080, height: 1440)).jpegData(compressionQuality: 0.9)).write(to: url)
            let item = MediaItem(
                id: "landscape-\(index)", kind: .photo, creationDate: start.addingTimeInterval(Double(index) * 1_800),
                pixelWidth: 1080, pixelHeight: 1440
            )
            media.append(ImportedMedia(item: item, url: url))
        }
        model.draft.media = media
        model.draft.lengthChoice = .preset(30)
        model.draft.title = Self.text("Summer by the lake", "Sommar vid sjön")
        model.draft.titleChosenByUser = true
        let input = GenerationInput(draft: model.draft)
        let output = try await FilmGenerator.generate(input, settings: .preview(.portrait)) { _, _ in }
        model.draft.adopt(output, from: input)
        model.preview = PreviewSession(edl: output.edl, built: output.built)
        await PreviewSession.waitUntilReady(model.preview!.player.currentItem!)

        let context = model.container.mainContext
        for (title, duration, age, look) in [
            (Self.text("Summer by the lake", "Sommar vid sjön"), 30.0, -3_600.0 * 2, Landscape.all[0]),
            (Self.text("Mountain hike", "Bergsvandring"), 95.0, -3_600.0 * 30, Landscape.all[2]),
            (Self.text("Weekend by the sea", "Helg vid havet"), 184.0, -3_600.0 * 24 * 9, Landscape.all[1]),
        ] {
            let project = SavedProject(id: UUID(), title: title, duration: duration, payload: Data())
            project.updatedAt = Date().addingTimeInterval(age)
            project.thumbnail = look.image(size: CGSize(width: 300, height: 400)).jpegData(compressionQuality: 0.85)
            context.insert(project)
        }
        try context.save()
        return model
    }

    // MARK: Drawing and saving

    /// The window at 3x: 1320 × 2868 for the 6.9" display.
    static func draw(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            _ = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    /// A SwiftUI view at exactly `size` pixels, without transparency.
    static func render(_ view: some View, size: CGSize) throws -> UIImage {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
        renderer.scale = 1
        renderer.isOpaque = true
        let image = try #require(renderer.uiImage)
        #expect(image.size == size, "\(image.size) instead of \(size)")
        return image
    }

    /// The full image in the folder and, in base64 lines, in the log.
    static func save(_ image: UIImage, name: String, folder: URL, png: Bool = false) throws {
        let jpeg = try #require(image.jpegData(compressionQuality: 0.88))
        if png {
            // The product page's header and search results images take PNG without
            // transparency, not JPEG; the log still carries the smaller JPEG to look at.
            let format = UIGraphicsImageRendererFormat()
            format.scale = image.scale
            format.opaque = true
            let opaque = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }
            let data = try #require(opaque.pngData())
            try data.write(to: folder.appending(path: "\(name).png"))
        } else {
            try jpeg.write(to: folder.appending(path: "\(name).jpg"))
        }
        print("store asset: \(name) \(Int(image.size.width * image.scale)) × \(Int(image.size.height * image.scale)), \(jpeg.count / 1024) KB")
        ScreenshotTests.log(name: (swedish ? "store-sv-" : "store-") + name, jpeg: jpeg)
    }
}

// MARK: - Painted landscapes

/// A simple painted landscape: a sky, a sun and layers of land or water.
@MainActor
struct Landscape {
    let sky: [UIColor]
    let sun: UIColor
    let sunAt: CGPoint
    /// From the back to the front: colour and heights (0 top, 1 bottom) across the picture.
    let layers: [(UIColor, [CGFloat])]

    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> UIColor {
        UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
    }

    static let all: [Landscape] = [
        // Sunset over the lake
        Landscape(sky: [rgb(255, 176, 102), rgb(232, 92, 112)], sun: rgb(255, 236, 200), sunAt: CGPoint(x: 0.62, y: 0.42),
                  layers: [(rgb(120, 70, 110), [0.55, 0.50, 0.53, 0.48, 0.52]), (rgb(70, 60, 110), [0.62, 0.62, 0.62, 0.62, 0.62]),
                           (rgb(46, 52, 92), [0.80, 0.78, 0.82, 0.79, 0.81])]),
        // Morning by the sea
        Landscape(sky: [rgb(120, 190, 240), rgb(214, 238, 250)], sun: rgb(255, 250, 230), sunAt: CGPoint(x: 0.28, y: 0.25),
                  layers: [(rgb(40, 120, 180), [0.58, 0.58, 0.58, 0.58, 0.58]), (rgb(28, 96, 160), [0.70, 0.69, 0.71, 0.70, 0.70]),
                           (rgb(240, 214, 160), [0.86, 0.82, 0.80, 0.83, 0.88])]),
        // Mountains
        Landscape(sky: [rgb(140, 176, 230), rgb(228, 236, 248)], sun: rgb(255, 255, 255), sunAt: CGPoint(x: 0.75, y: 0.2),
                  layers: [(rgb(150, 160, 190), [0.55, 0.30, 0.48, 0.26, 0.50]), (rgb(90, 102, 128), [0.62, 0.45, 0.58, 0.40, 0.60]),
                           (rgb(56, 92, 70), [0.82, 0.78, 0.84, 0.76, 0.80])]),
        // Meadow
        Landscape(sky: [rgb(170, 216, 250), rgb(236, 246, 255)], sun: rgb(255, 244, 190), sunAt: CGPoint(x: 0.2, y: 0.22),
                  layers: [(rgb(120, 180, 110), [0.60, 0.56, 0.58, 0.55, 0.60]), (rgb(84, 150, 84), [0.72, 0.70, 0.74, 0.69, 0.73]),
                           (rgb(56, 120, 66), [0.88, 0.86, 0.89, 0.85, 0.88])]),
        // Dusk in the city
        Landscape(sky: [rgb(40, 40, 96), rgb(214, 104, 120)], sun: rgb(255, 210, 170), sunAt: CGPoint(x: 0.5, y: 0.55),
                  layers: [(rgb(50, 44, 80), [0.62, 0.48, 0.55, 0.42, 0.58]), (rgb(30, 28, 56), [0.72, 0.60, 0.66, 0.56, 0.70]),
                           (rgb(18, 18, 34), [0.88, 0.86, 0.88, 0.86, 0.88])]),
        // Forest lake
        Landscape(sky: [rgb(200, 226, 214), rgb(246, 236, 210)], sun: rgb(255, 246, 220), sunAt: CGPoint(x: 0.66, y: 0.3),
                  layers: [(rgb(70, 120, 92), [0.50, 0.44, 0.48, 0.42, 0.47]), (rgb(120, 170, 180), [0.64, 0.64, 0.64, 0.64, 0.64]),
                           (rgb(44, 86, 64), [0.84, 0.80, 0.86, 0.82, 0.85])]),
        // Desert road
        Landscape(sky: [rgb(250, 200, 140), rgb(250, 236, 200)], sun: rgb(255, 250, 235), sunAt: CGPoint(x: 0.4, y: 0.3),
                  layers: [(rgb(214, 140, 96), [0.56, 0.50, 0.54, 0.47, 0.55]), (rgb(200, 112, 80), [0.66, 0.64, 0.67, 0.63, 0.66]),
                           (rgb(160, 88, 66), [0.86, 0.84, 0.87, 0.83, 0.86])]),
        // Northern lights
        Landscape(sky: [rgb(16, 36, 70), rgb(60, 170, 150)], sun: rgb(230, 250, 255), sunAt: CGPoint(x: 0.78, y: 0.18),
                  layers: [(rgb(30, 60, 90), [0.62, 0.52, 0.58, 0.50, 0.60]), (rgb(20, 40, 64), [0.74, 0.70, 0.76, 0.68, 0.73]),
                           (rgb(232, 240, 250), [0.88, 0.86, 0.89, 0.85, 0.88])]),
        // Beach at noon
        Landscape(sky: [rgb(90, 170, 240), rgb(190, 228, 250)], sun: rgb(255, 255, 240), sunAt: CGPoint(x: 0.5, y: 0.16),
                  layers: [(rgb(64, 190, 210), [0.56, 0.56, 0.56, 0.56, 0.56]), (rgb(40, 160, 196), [0.66, 0.66, 0.67, 0.65, 0.66]),
                           (rgb(250, 228, 180), [0.80, 0.76, 0.78, 0.74, 0.79])]),
        // Autumn hills
        Landscape(sky: [rgb(250, 214, 160), rgb(244, 160, 120)], sun: rgb(255, 240, 210), sunAt: CGPoint(x: 0.3, y: 0.4),
                  layers: [(rgb(200, 110, 70), [0.58, 0.52, 0.56, 0.50, 0.57]), (rgb(170, 80, 50), [0.70, 0.66, 0.72, 0.64, 0.70]),
                           (rgb(110, 60, 40), [0.86, 0.84, 0.88, 0.82, 0.86])]),
    ]

    func image(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sky.map(\.cgColor) as CFArray, locations: [0, 1])!
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height * 0.75), options: [.drawsAfterEndLocation])
            let radius = size.width * 0.11
            sun.withAlphaComponent(0.35).setFill()
            cg.fillEllipse(in: CGRect(x: size.width * sunAt.x - radius * 1.6, y: size.height * sunAt.y - radius * 1.6, width: radius * 3.2, height: radius * 3.2))
            sun.setFill()
            cg.fillEllipse(in: CGRect(x: size.width * sunAt.x - radius, y: size.height * sunAt.y - radius, width: radius * 2, height: radius * 2))
            for (color, heights) in layers {
                color.setFill()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: 0, y: size.height))
                let step = size.width / CGFloat(heights.count - 1)
                var previous = CGPoint(x: 0, y: size.height * heights[0])
                path.addLine(to: previous)
                for (index, height) in heights.enumerated().dropFirst() {
                    let point = CGPoint(x: step * CGFloat(index), y: size.height * height)
                    path.addQuadCurve(to: point, controlPoint: CGPoint(x: (previous.x + point.x) / 2, y: min(previous.y, point.y) - size.height * 0.02))
                    previous = point
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.close()
                path.fill()
            }
        }
    }
}

// MARK: - Layouts

/// The icon's warm gradient, still.
private struct StoreBackground: View {
    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: [[0, 0], [0.5, 0], [1, 0], [0, 0.5], [0.55, 0.45], [1, 0.5], [0, 1], [0.5, 1], [1, 1]],
            colors: [
                Brand.orange, Brand.orange, Brand.coral,
                Brand.coral, Brand.raspberry, Brand.deep,
                Brand.raspberry, Brand.deep, Brand.plum,
            ]
        )
    }
}

/// A screen of the app in a simple phone frame.
private struct PhoneShot: View {
    let image: UIImage
    let width: CGFloat

    var body: some View {
        let height = width * image.size.height / image.size.width
        // Corners and bezel follow the shorter side, so a landscape screen is not over-rounded.
        let side = min(width, height)
        Image(uiImage: image)
            .resizable()
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: side * 0.13, style: .continuous))
            .padding(side * 0.028)
            .background(Color.black, in: .rect(cornerRadius: side * 0.155, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: side * 0.06, y: side * 0.035)
    }
}

/// A 6.9" screenshot: a caption over the gradient, and the screen below it.
private struct StoreSlide: View {
    let caption: String
    let detail: String
    let screen: UIImage
    /// The 6.9" iPhone by default; the iPhone Duo's displays have sizes of their own.
    var size = CGSize(width: 1320, height: 2868)
    var screenWidth: CGFloat = 960

    var body: some View {
        // Text and spacing grow with the slide's shorter side, measured against the 6.9" iPhone.
        let unit = min(size.width, size.height) / 1320
        ZStack(alignment: .top) {
            StoreBackground()
            VStack(spacing: 70 * unit) {
                VStack(spacing: 30 * unit) {
                    Text(verbatim: caption)
                        .font(.system(size: 108 * unit, weight: .heavy, design: .rounded))
                        .lineSpacing(-6 * unit)
                    Text(verbatim: detail)
                        .font(.system(size: 50 * unit, weight: .medium, design: .rounded))
                        .opacity(0.92)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: Brand.plum.opacity(0.35), radius: 12 * unit, y: 4 * unit)
                // Two lines rather than a cut-off caption; the screen below moves down instead.
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 100 * unit)
                .padding(.top, 180 * unit)
                PhoneShot(image: screen, width: screenWidth)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .clipped()
    }
}

/// The product page header, 21:9: the name and promise on the left, three screens on the right.
private struct StoreHeader: View {
    let screens: [UIImage]

    var body: some View {
        ZStack {
            StoreBackground()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 56) {
                    AutoklippMark(size: 300, spread: 1)
                    Text(verbatim: "Autoklipp")
                        .font(.system(size: 200, weight: .heavy, design: .rounded))
                    Text(verbatim: StoreAssetsTests.text(
                        "Your photos and videos become a finished film, cut to the beat of the music.",
                        "Dina bilder och filmer blir en färdig film, klippt i takt med musiken."
                    ))
                        .font(.system(size: 80, weight: .semibold, design: .rounded))
                        .opacity(0.94)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(.white)
                .shadow(color: Brand.plum.opacity(0.35), radius: 14, y: 5)
                .frame(width: 1600, alignment: .leading)
                .padding(.leading, 300)
                Spacer(minLength: 0)
                ZStack {
                    PhoneShot(image: screens[0], width: 520)
                        .rotationEffect(.degrees(-7))
                        .offset(x: -470, y: 90)
                    PhoneShot(image: screens[2], width: 520)
                        .rotationEffect(.degrees(7))
                        .offset(x: 470, y: 90)
                    PhoneShot(image: screens[1], width: 600)
                }
                .frame(width: 1600)
                .padding(.trailing, 160)
            }
        }
        .frame(width: 3840, height: 1646)
        .clipped()
    }
}

/// The search results image, 3:2: the promise on top, three screens under it.
private struct StoreSearchResults: View {
    let screens: [UIImage]

    var body: some View {
        ZStack(alignment: .top) {
            StoreBackground()
            VStack(spacing: 110) {
                VStack(spacing: 36) {
                    Text(verbatim: StoreAssetsTests.text("Your photos, cut to the beat", "Dina bilder, klippta i takt"))
                        .font(.system(size: 190, weight: .heavy, design: .rounded))
                    Text(verbatim: StoreAssetsTests.text(
                        "Pick photos and videos, a length and a style. Autoklipp makes the film.",
                        "Välj bilder och filmer, en längd och en stil. Autoklipp gör filmen."
                    ))
                        .font(.system(size: 76, weight: .semibold, design: .rounded))
                        .opacity(0.94)
                }
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                .shadow(color: Brand.plum.opacity(0.35), radius: 14, y: 5)
                .padding(.horizontal, 240)
                .padding(.top, 170)
                HStack(spacing: 140) {
                    PhoneShot(image: screens[0], width: 760)
                    PhoneShot(image: screens[1], width: 860)
                    PhoneShot(image: screens[2], width: 760)
                }
            }
        }
        .frame(width: 3840, height: 2560, alignment: .top)
        .clipped()
    }
}
