import FITgapCore
import MapKit
import SwiftUI

/// Map preview of the recorded positions; hidden when the file has no route.
/// Virtual rides (e.g. Zwift, MyWhoosh) are drawn at the coordinates of their game world.
struct RouteSection: View {
    let activity: ActivityRecord
    let route: [FITActivity.Coordinate]
    /// Set once reading has finished; a file that turns out to hold no usable route then hides the section.
    var read = false
    /// Photos taken during the activity; small marks on the preview, tappable thumbnails on the full-screen map.
    @ObservedObject var photos: ActivityPhotos
    @State private var expanded = false
    @AppStorage(MapAppearance.key) private var appearance = MapAppearance.standard

    var body: some View {
        // The section exists from the start when the cached metrics report positions, so the list never has to
        // insert it later; the map fills in once the route is read.
        if RouteThumbnail.hasRoute(activity), !(read && route.count < 2) {
            Section {
                Button { expanded = true } label: {
                    ZStack {
                        Rectangle().fill(.quaternary)
                        if route.count > 1 {
                            // A new activity gets a new map, so the camera frames its route.
                            RouteMap(route: route, interactive: false, photos: photos.placed).id(activity.id)
                        } else { ProgressView() }
                    }
                    .frame(height: 220)
                }
                .buttonStyle(.plain)
                .disabled(route.count < 2)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel(isVirtual ? "Virtuelle Strecke auf der Karte" : "Strecke auf der Karte")
                .accessibilityHint("Öffnet die Karte")
                .accessibilityIdentifier("route-map")
                .sheet(isPresented: $expanded) {
                    NavigationStack {
                        RouteMap(route: route, interactive: true, photos: photos.placed) { photo in
                            Task { await photos.open(photo, fromMap: true) }
                        }
                            .ignoresSafeArea(edges: .bottom)
                            .overlay {
                                if photos.preparing {
                                    ProgressView("Fotos werden geladen …")
                                        .padding(12)
                                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                                }
                            }
                            .photoViewer($photos.mapPreview, in: photos.previewURLs)
                            .navigationTitle(activity.displayName)
                            .navigationBarTitleDisplayMode(.inline)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Fertig", systemImage: "checkmark") { expanded = false }
                                }
                                ToolbarItem {
                                    Menu {
                                        Picker("Kartentyp", selection: $appearance) {
                                            ForEach(MapAppearance.allCases) { Text($0.title).tag($0) }
                                        }
                                    } label: {
                                        Label("Kartentyp", systemImage: appearance == .satellite ? "globe.europe.africa" : "map")
                                    }
                                    .accessibilityIdentifier("route-map-appearance")
                                }
                            }
                    }
                }
            } header: {
                Text("Karte")
            } footer: {
                if isVirtual { Text("Virtuelle Strecke: Die Koordinaten gehören zur Spielwelt und liegen oft abseits echter Straßen.") }
            }
        }
    }

    private var isVirtual: Bool { Self.isVirtual(activity) }

    static func isVirtual(_ activity: ActivityRecord) -> Bool {
        activity.metrics?.subSport == 58 || activity.source == .zwift || activity.source == .mywhoosh
    }

    /// Reloads when another file version or library (demo/real) is shown.
    static func loadID(_ activity: ActivityRecord, model: AppModel) -> String {
        "\(model.libraryGeneration)-\(activity.id)-\(activity.status == .available ? activity.receipt?.sha256 ?? "" : "")"
    }

    /// Reads the positions off the main thread; empty when the file is missing or has no route.
    static func load(_ activity: ActivityRecord, model: AppModel) async -> [FITActivity.Coordinate] {
        guard activity.status == .available else { return [] }
        let library = model.library
        return await Task.detached(priority: .userInitiated) {
            (try? library.activity(for: activity))?.route() ?? []
        }.value
    }
}

/// The route with start and finish, coloured by speed like the list preview; the camera frames the whole route.
private struct RouteMap: View {
    let route: [FITActivity.Coordinate]
    let interactive: Bool
    var photos: [ActivityPhoto] = []
    var open: ((ActivityPhoto) -> Void)?
    @AppStorage(MapAppearance.key) private var appearance = MapAppearance.standard
    /// Height of the visible region in metres; photos closer than a few percent of it share one pin.
    @State private var span = 0.0

    /// One pin per photo on the preview; on the zoomable map nearby photos stack until zoomed in.
    private var photoGroups: [[ActivityPhoto]] {
        guard interactive else { return photos.map { [$0] } }
        return TrackPlacement.groups(photos, meters: max(span * 0.06, 15)) { ($0.coordinate!.latitude, $0.coordinate!.longitude) }
    }

    /// Consecutive segments of the same colour share one line, so MapKit draws a few dozen lines instead of thousands.
    private var runs: [(id: Int, color: Color, points: [CLLocationCoordinate2D])] {
        let colors = RouteDrawing.colors(for: route)
        var result: [(id: Int, color: Color, points: [CLLocationCoordinate2D])] = []
        var bin: Int?
        for index in 1..<route.count {
            var hue: CGFloat = 0
            colors[index].getHue(&hue, saturation: nil, brightness: nil, alpha: nil)
            let next = Int((hue * 60).rounded())
            if next != bin || result.isEmpty {
                result.append((result.count, Color(uiColor: colors[index]), [route[index - 1].location]))
                bin = next
            }
            result[result.count - 1].points.append(route[index].location)
        }
        return result
    }

    var body: some View {
        let style = StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round)
        Map(initialPosition: .automatic, interactionModes: interactive ? .all : []) {
            MapPolyline(coordinates: route.map(\.location))
                .stroke(Color(uiColor: RouteDrawing.casing), style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
            ForEach(runs, id: \.id) { run in
                MapPolyline(coordinates: run.points).stroke(run.color, style: style)
            }
            if let first = route.first { Marker("Start", systemImage: "flag", coordinate: first.location).tint(.green) }
            if let last = route.last { Marker("Ziel", systemImage: "flag.checkered", coordinate: last.location).tint(.red) }
            ForEach(photoGroups, id: \.first!.id) { group in
                Annotation(String(localized: "Foto"), coordinate: group[0].coordinate!, anchor: .center) {
                    if interactive {
                        Button { open?(group[0]) } label: { PhotoPin(photos: group, large: true) }
                            .buttonStyle(.plain)
                            .accessibilityLabel(group.count > 1
                                ? Text("\(group.count) Fotos") : Text("Foto, \(group[0].date.formatted(date: .omitted, time: .shortened))"))
                            .accessibilityHint("Öffnet das Foto in groß")
                    } else {
                        PhotoPin(photos: group, large: false).accessibilityHidden(true)
                    }
                }
                .annotationTitles(.hidden)
            }
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            if interactive { span = context.region.span.latitudeDelta * 111_000 }
        }
        .mapStyle(appearance.mapStyle)
        .mapControls {
            if interactive {
                MapCompass()
                MapScaleView()
            }
        }
    }
}
