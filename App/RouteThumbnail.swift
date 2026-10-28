import FITgapCore
import MapKit
import SwiftUI

/// Wide map image of an activity's route for the list, coloured by speed like the Fitness app:
/// red is slow, yellow average, green fast. Only rows whose file has positions show it.
/// The route is drawn at once from its stored preview; the map underneath fades in once MapKit delivers it.
struct RouteThumbnail: View {
    let activity: ActivityRecord
    let library: ActivityLibrary
    /// The topmost rows, which an iPhone shows right after the app starts; their maps are made first.
    var urgent = false
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale
    @AppStorage(MapAppearance.key) private var appearance = MapAppearance.standard
    @State private var route: [FITActivity.Coordinate]?
    /// The map with the size key it was made for; a map for another size is never stretched into the frame.
    @State private var map: (key: String, image: UIImage)?

    var body: some View {
        // The always-present clear layer carries the size and the loading task; an empty view would never start it.
        Color.clear
            .aspectRatio(3 / 2, contentMode: .fit)
            .overlay {
                GeometryReader { proxy in
                    let points = route ?? RouteThumbnails.shared.cachedRoute(activity)
                    let image = map?.key == key(proxy.size) ? map?.image : RouteThumbnails.shared.cachedMap(key(proxy.size))
                    ZStack {
                        if let image {
                            Image(uiImage: image).resizable().scaledToFill()
                                .transition(.opacity)
                        } else if let points {
                            Canvas { context, size in RouteDrawing.draw(points, in: context, size: size) }
                        }
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .animation(.easeIn(duration: 0.2), value: image != nil)
                    // A map made at another size would be scaled and blur the line, so a new size makes a new map.
                    .task(id: key(proxy.size)) {
                        guard proxy.size.width > 0 else { return }
                        guard let loaded = await RouteThumbnails.shared.route(activity, library: library) else { return }
                        route = loaded
                        // While the list settles its layout the size changes for a moment; only a size that holds
                        // starts a snapshot, so no request is spent on a size that is gone a frame later.
                        if RouteThumbnails.shared.cachedMap(key(proxy.size)) == nil {
                            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                        }
                        let made = await RouteThumbnails.shared.map(key: key(proxy.size), route: loaded, size: pixelAligned(proxy.size),
                                                               scale: displayScale, dark: colorScheme == .dark,
                                                               appearance: appearance, urgent: urgent)
                        if let made { map = (key(proxy.size), made) }
                    }
                }
            }
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityHidden(true)
    }

    /// Rounded up to whole pixels, so the map image fills the frame without a blank edge.
    private func pixelAligned(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width * displayScale).rounded(.up) / displayScale, height: (size.height * displayScale).rounded(.up) / displayScale)
    }

    /// A new file, appearance, map type or size gets its own map.
    private func key(_ size: CGSize) -> String {
        "\(activity.id)-\(activity.receipt?.sha256 ?? "")-\(colorScheme == .dark ? "dark" : "light")-\(appearance.rawValue)-\(Int(size.width))x\(Int(size.height))"
    }

    /// Only files whose cached metrics report positions get a map, so rows without a route keep their layout.
    static func hasRoute(_ activity: ActivityRecord) -> Bool {
        activity.status == .available && activity.metrics?.richness?.channels.contains(.position) == true
    }
}

/// Keeps routes and rendered maps in memory only; the system frees them under memory pressure.
@MainActor
final class RouteThumbnails {
    static let shared = RouteThumbnails()
    private let routes = NSCache<NSString, RouteBox>()
    private let maps = NSCache<NSString, UIImage>()
    /// Maps of the topmost rows being made; the others wait until these are done.
    private var urgentRunning = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    private final class RouteBox {
        let points: [FITActivity.Coordinate]
        init(_ points: [FITActivity.Coordinate]) { self.points = points }
    }

    private init() {
        // Map images were stored as JPEGs by an earlier build; they are no longer used.
        let old = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("RouteMaps")
        Task.detached(priority: .background) { try? FileManager.default.removeItem(at: old) }
    }

    private func routeKey(_ activity: ActivityRecord) -> NSString { "\(activity.id)-\(activity.receipt?.sha256 ?? "")" as NSString }

    func cachedRoute(_ activity: ActivityRecord) -> [FITActivity.Coordinate]? {
        routes.object(forKey: routeKey(activity)).flatMap { $0.points.count > 1 ? $0.points : nil }
    }
    func cachedMap(_ key: String) -> UIImage? { maps.object(forKey: key as NSString) }

    /// Reads the stored preview (or, once, the FIT) off the main thread; nil when the file has no route.
    func route(_ activity: ActivityRecord, library: ActivityLibrary) async -> [FITActivity.Coordinate]? {
        if let box = routes.object(forKey: routeKey(activity)) { return box.points.count > 1 ? box.points : nil }
        let points = await Task.detached(priority: .userInitiated) { (try? library.routePreview(for: activity)) ?? [] }.value
        routes.setObject(RouteBox(points), forKey: routeKey(activity))
        return points.count > 1 ? points : nil
    }

    /// Drops what is held for a deleted file.
    func remove(_ activity: ActivityRecord) {
        routes.removeObject(forKey: routeKey(activity))
        maps.removeAllObjects()
    }

    func map(key: String, route: [FITActivity.Coordinate], size: CGSize, scale: CGFloat, dark: Bool, appearance: MapAppearance,
             urgent: Bool) async -> UIImage? {
        if let cached = cachedMap(key) { return cached }
        if urgent {
            urgentRunning += 1
        } else {
            while urgentRunning > 0 { await withCheckedContinuation { waiting.append($0) } }
            guard !Task.isCancelled else { return nil }
        }
        defer {
            if urgent {
                urgentRunning -= 1
                if urgentRunning == 0 { waiting.forEach { $0.resume() }; waiting.removeAll() }
            }
        }
        let started = ContinuousClock.now
        // Trait collections are built on the main actor; the snapshot itself runs off it.
        let traits = UITraitCollection { traits in
            traits.displayScale = scale
            traits.userInterfaceStyle = dark ? .dark : .light
        }
        guard let image = await Self.snapshot(route, size: size, traits: traits, appearance: appearance) else { return nil }
        maps.setObject(image, forKey: key as NSString)
        if urgent {
            let elapsed = ContinuousClock.now - started
            StartupLog.mark("route map ready, snapshot took \(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000) ms")
        }
        return image
    }

    /// Makes the map and draws the route on a background queue; MapKit would otherwise deliver the snapshot
    /// on the main thread, which is busy while the app starts and syncs.
    private nonisolated static func snapshot(_ route: [FITActivity.Coordinate], size: CGSize, traits: UITraitCollection,
                                             appearance: MapAppearance) async -> UIImage? {
        let options = MKMapSnapshotter.Options()
        options.mapRect = RouteDrawing.mapRect(route)
        options.size = size
        options.traitCollection = traits
        options.preferredConfiguration = appearance.snapshotConfiguration
        let snapshotter = MKMapSnapshotter(options: options)
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            snapshotter.start(with: .global(qos: .userInitiated)) { snapshot, _ in
                guard let snapshot else { continuation.resume(returning: nil); return }
                let format = UIGraphicsImageRendererFormat()
                format.scale = snapshot.image.scale
                format.opaque = true
                let image = UIGraphicsImageRenderer(size: snapshot.image.size, format: format).image { context in
                    snapshot.image.draw(at: .zero)
                    RouteDrawing.stroke(route.map { snapshot.point(for: $0.location) }, colors: RouteDrawing.colors(for: route),
                                        in: context.cgContext)
                }
                continuation.resume(returning: image)
            }
        }
    }
}

/// The map type chosen in the settings, used by the list preview and the details map.
enum MapAppearance: String, CaseIterable, Identifiable {
    case standard, satellite

    static let key = "mapAppearance"
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .standard: "Standard"
        case .satellite: "Satellit"
        }
    }

    /// The regular map with roads, places, terrain and points of interest.
    var snapshotConfiguration: MKMapConfiguration {
        switch self {
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat)
            configuration.showsTraffic = false
            return configuration
        case .satellite:
            let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
            configuration.showsTraffic = false
            return configuration
        }
    }

    var mapStyle: MapStyle {
        switch self {
        case .standard: .standard
        case .satellite: .hybrid
        }
    }
}

extension FITActivity.Coordinate {
    var location: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
}

/// Shared geometry and colours for the list preview and the details map.
enum RouteDrawing {
    /// The route's bounds with room around it; tiny routes still show their surroundings.
    static func mapRect(_ route: [FITActivity.Coordinate]) -> MKMapRect {
        let points = route.map { MKMapPoint($0.location) }
        let bounds = MKPolyline(points: points, count: points.count).boundingMapRect
        let inset = -max(bounds.width, bounds.height, 2000) * 0.12
        return bounds.insetBy(dx: inset, dy: inset)
    }

    /// Draws the route without a map, framed like the snapshot: the map rect fitted and centred in the view.
    static func draw(_ route: [FITActivity.Coordinate], in context: GraphicsContext, size: CGSize) {
        let rect = mapRect(route)
        let factor = min(size.width / rect.width, size.height / rect.height)
        let origin = CGPoint(x: (size.width - rect.width * factor) / 2, y: (size.height - rect.height * factor) / 2)
        let points = route.map { coordinate -> CGPoint in
            let point = MKMapPoint(coordinate.location)
            return CGPoint(x: origin.x + (point.x - rect.minX) * factor, y: origin.y + (point.y - rect.minY) * factor)
        }
        context.withCGContext { stroke(points, colors: colors(for: route), in: $0) }
    }

    static func stroke(_ points: [CGPoint], colors: [UIColor], in cg: CGContext) {
        guard points.count > 1 else { return }
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        // A dark casing keeps the coloured line readable on light and dark maps.
        cg.setLineWidth(6)
        cg.setStrokeColor(casing.cgColor)
        cg.addLines(between: points)
        cg.strokePath()
        cg.setLineWidth(4)
        for index in 1..<points.count {
            cg.setStrokeColor(colors[index].cgColor)
            cg.move(to: points[index - 1])
            cg.addLine(to: points[index])
            cg.strokePath()
        }
    }

    static let casing = UIColor.black.withAlphaComponent(0.35)

    /// Pastel shades: soft coral for the slowest, mint for the fastest segments; outliers beyond the 10th/90th percentile are clamped.
    /// The colour of a point belongs to the segment that ends there.
    static func colors(for route: [FITActivity.Coordinate]) -> [UIColor] {
        let speeds = route.compactMap(\.speed).sorted()
        guard let low = speeds.dropFirst(speeds.count / 10).first, let high = speeds.dropLast(speeds.count / 10).last,
              high > low else { return route.map { _ in UIColor(hue: 1 / 3, saturation: 0.5, brightness: 1, alpha: 1) } }
        return route.map { coordinate in
            guard let speed = coordinate.speed else { return UIColor(hue: 1 / 6, saturation: 0.5, brightness: 1, alpha: 1) }
            let share = min(max((speed - low) / (high - low), 0), 1)
            return UIColor(hue: share / 3, saturation: 0.5, brightness: 1, alpha: 1)
        }
    }
}
