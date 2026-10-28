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
                            RouteMap(route: route, interactive: false).id(activity.id)
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
                        RouteMap(route: route, interactive: true)
                            .ignoresSafeArea(edges: .bottom)
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

    private var isVirtual: Bool {
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
    @AppStorage(MapAppearance.key) private var appearance = MapAppearance.standard

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
