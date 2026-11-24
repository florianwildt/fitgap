import CoreLocation
import FITgapCore
import Photos
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// A photo taken during an activity; `coordinate` is its own location or the route position at its time.
struct ActivityPhoto: Identifiable, Equatable {
    let id: String
    let date: Date
    var coordinate: CLLocationCoordinate2D?

    static func == (a: ActivityPhoto, b: ActivityPhoto) -> Bool {
        a.id == b.id && a.coordinate?.latitude == b.coordinate?.latitude && a.coordinate?.longitude == b.coordinate?.longitude
    }
}

/// Photos from the library taken during one activity. Nothing is copied into FITgap; only photos opened in the
/// large view are written to temporary files for viewing and sharing and removed when the details close.
@MainActor
final class ActivityPhotos: ObservableObject {
    @Published private(set) var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published private(set) var items: [ActivityPhoto] = []
    @Published private(set) var loaded = false
    @Published private(set) var preparing = false
    /// Photo opened from the details list or from the full-screen map, which is a separate sheet.
    @Published var listPreview: URL?
    @Published var mapPreview: URL?
    @Published private(set) var previewURLs: [URL] = []

    private var files: [String: URL] = [:]
    private var shown: DateInterval?
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ActivityPhotos-\(UUID().uuidString)", isDirectory: true)

    var hasAccess: Bool { status == .authorized || status == .limited }
    var placed: [ActivityPhoto] { items.filter { $0.coordinate != nil } }

    func requestAccess() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// Finds the photos (no screenshots, no videos) taken from two minutes before the start to two minutes after the end.
    /// Photos without their own location are placed along the track, which is only read when such photos exist.
    func load(_ interval: DateInterval, onMap: Bool, track: @escaping @Sendable () async -> [TrackPlacement.Point]) async {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        // Side by side the details stay while another activity is selected; its photos must not show meanwhile.
        if interval != shown {
            shown = interval
            items = []
            loaded = false
            removeFiles()
        }
        guard hasAccess else { items = []; loaded = true; return }
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "creationDate >= %@ AND creationDate <= %@ AND mediaType == %d",
                                        interval.start.addingTimeInterval(-120) as NSDate,
                                        interval.end.addingTimeInterval(120) as NSDate, PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var found: [ActivityPhoto] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            guard !asset.mediaSubtypes.contains(.photoScreenshot), let date = asset.creationDate else { return }
            found.append(ActivityPhoto(id: asset.localIdentifier, date: date, coordinate: asset.location?.coordinate))
        }
        if !onMap {
            // Virtual worlds and activities without route: own photo locations would not match the map.
            for index in found.indices { found[index].coordinate = nil }
        } else if found.contains(where: { $0.coordinate == nil }) {
            let points = await track()
            guard !Task.isCancelled else { return }
            for index in found.indices where found[index].coordinate == nil {
                if let point = TrackPlacement.position(at: found[index].date, in: points) {
                    found[index].coordinate = CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)
                }
            }
        }
        items = found
        loaded = true
    }

    /// Writes the activity's photos once to temporary files and opens the large view at the tapped one.
    func open(_ photo: ActivityPhoto, fromMap: Bool) async {
        guard !preparing else { return }
        preparing = true
        defer { preparing = false }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: items.map(\.id), options: nil)
        var byID: [String: PHAsset] = [:]
        assets.enumerateObjects { asset, _, _ in byID[asset.localIdentifier] = asset }
        for (index, item) in items.enumerated() where files[item.id] == nil {
            guard let asset = byID[item.id], let url = await export(asset, index: index) else { continue }
            files[item.id] = url
        }
        previewURLs = items.compactMap { files[$0.id] }
        guard let url = files[photo.id] else { return }
        if fromMap { mapPreview = url } else { listPreview = url }
    }

    func removeFiles() {
        try? FileManager.default.removeItem(at: folder)
        files = [:]
        previewURLs = []
    }

    /// The current version as stored, downloading it from iCloud Photos when needed.
    private func export(_ asset: PHAsset, index: Int) async -> URL? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.version = .current
        options.deliveryMode = .highQualityFormat
        let result: (Data, String?)? = await withCheckedContinuation { continuation in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                continuation.resume(returning: data.map { ($0, uti) })
            }
        }
        guard let (data, uti) = result else { return nil }
        let ext = uti.flatMap { UTType($0)?.preferredFilenameExtension } ?? "jpg"
        let time = asset.creationDate?.formatted(.dateTime.hour().minute().second()).replacingOccurrences(of: ":", with: ".") ?? ""
        let url = folder.appendingPathComponent("\(String(format: "%02d", index + 1)) \(time).\(ext)")
        do { try data.write(to: url, options: .atomic) } catch { return nil }
        return url
    }
}

/// The large view of the activity's photos: swipe sideways between them, pinch to look closer, share or close.
/// From iOS 18 it zooms in and closes by swiping down, like Photos.
struct PhotoViewer: View {
    let urls: [URL]
    @State var current: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $current) {
                ForEach(urls, id: \.self) { url in
                    PhotoPage(url: url).tag(url)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .navigationTitle(urls.count > 1 ? String(localized: "\((urls.firstIndex(of: current) ?? 0) + 1) von \(urls.count)") : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Schließen", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: current)
                }
            }
        }
        .accessibilityIdentifier("photo-viewer")
    }
}

/// One photo, loaded at screen size; pinching enlarges it until released.
private struct PhotoPage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var scale = 1.0
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .accessibilityLabel(Text("Foto"))
                        .gesture(MagnifyGesture()
                            .onChanged { scale = max(1, $0.magnification) }
                            .onEnded { _ in withAnimation(.spring) { scale = 1 } })
                } else {
                    ProgressView()
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .task(id: url) {
                let pixels = max(proxy.size.width, proxy.size.height) * displayScale
                image = await Task.detached { Self.load(url, pixels: pixels) }.value
            }
        }
    }

    /// Downsampled decode, so large photos do not fill the memory.
    nonisolated private static func load(_ url: URL, pixels: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: max(pixels, 1)]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map(UIImage.init)
    }
}

extension View {
    /// Shows the photo viewer full screen while `url` is set.
    func photoViewer(_ url: Binding<URL?>, in urls: [URL]) -> some View {
        modifier(PhotoViewerPresentation(url: url, urls: urls))
    }
}

private struct PhotoViewerPresentation: ViewModifier {
    @Binding var url: URL?
    let urls: [URL]
    @Namespace private var namespace

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: Binding(get: { url != nil }, set: { if !$0 { url = nil } })) {
            if let start = url {
                if #available(iOS 18, *) {
                    PhotoViewer(urls: urls, current: start)
                        .navigationTransition(.zoom(sourceID: "photo", in: namespace))
                } else {
                    PhotoViewer(urls: urls, current: start)
                }
            }
        }
    }
}

/// Square thumbnail of a library photo, loaded at the size it is shown.
struct PhotoThumbnail: View {
    let id: String
    let side: CGFloat
    @State private var image: UIImage?
    @Environment(\.displayScale) private var scale

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
            }
        }
        .frame(width: side, height: side)
        .clipped()
        .task(id: id) {
            let pixels = side * scale
            image = await PhotoImages.shared.image(id: id, pixels: pixels)
        }
    }
}

@MainActor
final class PhotoImages {
    static let shared = PhotoImages()
    private let manager = PHCachingImageManager()

    func image(id: String, pixels: CGFloat) async -> UIImage? {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        return await withCheckedContinuation { continuation in
            manager.requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels), contentMode: .aspectFill,
                                 options: options) { image, _ in continuation.resume(returning: image) }
        }
    }
}

/// Photos of the activity as a row of thumbnails; asks for library access only when tapped.
struct PhotoSection: View {
    @ObservedObject var photos: ActivityPhotos
    let reload: () -> Void
    /// Thumbnail size, growing with the text size.
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 180

    /// With access the section only appears once photos were found, so activities without photos show nothing.
    private var hidden: Bool { photos.hasAccess && photos.items.isEmpty }

    var body: some View {
        if !hidden { section }
    }

    private var section: some View {
        Section {
            switch photos.status {
            case .notDetermined:
                Button("Fotos dieser Aktivität anzeigen", systemImage: "photo.on.rectangle") {
                    Task {
                        await photos.requestAccess()
                        reload()
                    }
                }
                .accessibilityIdentifier("photos-request")
            case .denied, .restricted:
                Text("FITgap hat keinen Zugriff auf deine Fotos.").foregroundStyle(.secondary)
                settingsButton
            default:
                strip
                if photos.status == .limited { settingsButton }
            }
        } header: {
            Text("Fotos")
        } footer: {
            switch photos.status {
            case .notDetermined:
                Text("FITgap sucht in deiner Mediathek nach Fotos, die während der Aktivität entstanden sind, und zeigt sie hier und auf der Karte. Die Fotos bleiben auf dem Gerät.")
            case .limited:
                Text("Du hast FITgap nur ausgewählte Fotos freigegeben. Weitere Fotos gibst du in den Einstellungen frei.")
            default:
                EmptyView()
            }
        }
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 8) {
                ForEach(photos.items) { photo in
                    Button {
                        Task { await photos.open(photo, fromMap: false) }
                    } label: {
                        PhotoThumbnail(id: photo.id, side: side).clipShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text("Foto, \(photo.date.formatted(date: .omitted, time: .shortened))"))
                    .accessibilityHint("Öffnet das Foto in groß")
                }
            }
            .padding(.vertical, 4)
        }
        .overlay {
            if photos.preparing {
                ProgressView("Fotos werden geladen …")
                    .padding(10)
                    .background(.regularMaterial, in: .rect(cornerRadius: 10))
            }
        }
        .accessibilityIdentifier("photos-strip")
    }

    private var settingsButton: some View {
        Button("In den Einstellungen ändern", systemImage: "gear") {
            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        }
    }
}

/// Map pin of one photo or several taken close together.
struct PhotoPin: View {
    let photos: [ActivityPhoto]
    let large: Bool

    var body: some View {
        if large {
            PhotoThumbnail(id: photos[0].id, side: 44)
                .clipShape(.rect(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                .overlay(alignment: .topTrailing) {
                    if photos.count > 1 {
                        Text("\(photos.count)")
                            .font(.caption2.weight(.bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor, in: .capsule)
                            .offset(x: 8, y: -8)
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(.rect)
        } else {
            Image(systemName: "camera.fill")
                .font(.system(size: 8))
                .foregroundStyle(.white)
                .padding(4)
                .background(Color.accentColor, in: .circle)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
        }
    }
}
