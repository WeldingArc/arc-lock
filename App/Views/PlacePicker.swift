import CoreLocation
import MapKit
import SwiftUI

/// Picks a place block's place: search, or tap the map, then set how big the circle is. Searching uses Apple Maps;
/// nothing about it is stored except the chosen spot.
struct PlacePicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var watcher = PlaceWatcher.shared
    let initial: PlaceSpot?
    let onDone: (PlaceSpot) -> Void

    @State private var center: CLLocationCoordinate2D?
    @State private var radius = Limits.defaultPlaceRadius
    @State private var name = ""
    @State private var camera: MapCameraPosition = .automatic
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var searching = false
    @State private var noResults = false
    /// What the map shows now: searches look there first.
    @State private var visible: MKCoordinateRegion?
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            MapReader { proxy in
                Map(position: $camera) {
                    UserAnnotation()
                    if let center {
                        MapCircle(center: center, radius: radius)
                            .foregroundStyle(Palette.brass.opacity(0.22))
                            .stroke(Palette.brass, lineWidth: 2)
                        Marker(name.isEmpty ? String(localized: "Place") : name, systemImage: "lock.fill", coordinate: center)
                            .tint(Palette.brass)
                    }
                }
                .mapControls {
                    MapUserLocationButton()
                    MapCompass()
                }
                .onMapCameraChange(frequency: .onEnd) { context in visible = context.region }
                .onTapGesture { point in
                    guard let c = proxy.convert(point, from: .local) else { return }
                    center = c
                    results = []
                }
            }
            .ignoresSafeArea(edges: .bottom)
            .safeAreaInset(edge: .top) { searchBar }
            .safeAreaInset(edge: .bottom) { bottomPanel }
            .navigationTitle("Place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { done() }.fontWeight(.semibold).disabled(center == nil)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var searchBar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search for a place", text: $query)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            if noResults {
                Text("No places found. Try another name, or tap the map.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .padding(.top, 6)
            }
            if !results.isEmpty {
                VStack(spacing: 0) {
                    ForEach(results, id: \.self) { item in
                        Button { pick(item) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? String(localized: "Place")).foregroundStyle(Palette.ink)
                                if let line = address(item) {
                                    Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if item != results.last { Divider().padding(.leading, 14) }
                    }
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.top, 6)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private var bottomPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if center == nil {
                Text("Search, or tap the map where the block should start.")
                    .font(.subheadline).foregroundStyle(.secondary)
                if watcher.access == .always || watcher.access == .whileUsing {
                    Button { useMyLocation() } label: { Label("Use my location", systemImage: "location.fill") }
                        .disabled(freshLocation == nil)
                }
            } else {
                TextField("Name (Library, School…)", text: $name)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.done)
                    .padding(.horizontal, 12).frame(height: 40)
                    .background(Palette.wash(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Text("Size").foregroundStyle(Palette.ink)
                    Spacer()
                    Text(distanceText(radius)).monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $radius, in: Limits.placeRadius, step: 50)
                Text("iOS notices arriving and leaving within a few minutes. A bigger circle works more reliably.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        watcher.locate()
        if let spot = initial {
            let c = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
            center = c
            radius = spot.radius
            name = spot.name
            camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: spot.radius * 5, longitudinalMeters: spot.radius * 5))
        } else {
            camera = .userLocation(fallback: .automatic)
        }
    }

    /// Where you are now: a fix from the last two minutes, good to about 200 m (an old one could pin another place).
    private var freshLocation: CLLocation? {
        guard let l = watcher.location, l.timestamp.timeIntervalSinceNow > -120, l.horizontalAccuracy >= 0,
              l.horizontalAccuracy <= 200 else { return nil }
        return l
    }

    private func useMyLocation() {
        guard let here = freshLocation?.coordinate else { return }
        center = here
        camera = .region(MKCoordinateRegion(center: here, latitudinalMeters: radius * 5, longitudinalMeters: radius * 5))
    }

    private func search() {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let visible {
            request.region = visible
        } else if let here = watcher.location?.coordinate {
            request.region = MKCoordinateRegion(center: here, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        searching = true
        noResults = false
        MKLocalSearch(request: request).start { response, error in
            #if DEBUG
            NSLog("place search: \(response?.mapItems.count ?? -1) results, error: \(String(describing: error))")
            #endif
            searching = false
            results = Array((response?.mapItems ?? []).prefix(5))
            noResults = results.isEmpty
        }
    }

    private func pick(_ item: MKMapItem) {
        let c = item.placemark.coordinate
        center = c
        name = item.name ?? name
        results = []
        query = ""
        camera = .region(MKCoordinateRegion(center: c, latitudinalMeters: radius * 5, longitudinalMeters: radius * 5))
    }

    private func address(_ item: MKMapItem) -> String? {
        let p = item.placemark
        let parts = [p.thoroughfare, p.locality].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private func done() {
        guard let center else { return }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        onDone(PlaceSpot(latitude: center.latitude, longitude: center.longitude, radius: radius,
                         name: label.isEmpty ? String(localized: "Pinned place") : label))
        dismiss()
    }
}

/// "150 m" or "1 km" in the user's units.
func distanceText(_ meters: Double) -> String {
    let f = MeasurementFormatter()
    f.unitOptions = .naturalScale
    f.numberFormatter.maximumFractionDigits = meters >= 1000 ? 1 : 0
    return f.string(from: Measurement(value: meters, unit: UnitLength.meters))
}

/// A small, still map of a place block's circles (in the editor).
struct PlacesPreview: View {
    let spots: [PlaceSpot]

    var body: some View {
        Map(initialPosition: .region(Self.region(around: spots)), interactionModes: []) {
            ForEach(Array(spots.enumerated()), id: \.offset) { _, spot in
                let c = CLLocationCoordinate2D(latitude: spot.latitude, longitude: spot.longitude)
                MapCircle(center: c, radius: spot.radius)
                    .foregroundStyle(Palette.brass.opacity(0.22))
                    .stroke(Palette.brass, lineWidth: 2)
                Marker(spot.name, systemImage: "lock.fill", coordinate: c)
                    .tint(Palette.brass)
            }
        }
        .id(spots)            // other places redraw the map around them
        .accessibilityLabel(Text(spots.map(\.name).joined(separator: ", ")))
    }

    /// Every circle in view, with some room around them.
    static func region(around spots: [PlaceSpot]) -> MKCoordinateRegion {
        guard let first = spots.first else { return MKCoordinateRegion() }
        let lats = spots.map(\.latitude), lons = spots.map(\.longitude)
        let margin = (spots.map(\.radius).max() ?? first.radius) * 4
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2, longitude: (lons.min()! + lons.max()!) / 2)
        // far-apart places (another city, across the date line) just zoom out: MapKit rejects spans past the globe
        let latSpan = min((lats.max()! - lats.min()!) * 111_000 * 1.3 + margin, 15_000_000)
        let lonSpan = min((lons.max()! - lons.min()!) * 111_000 * max(cos(center.latitude * .pi / 180), 0.1) * 1.3 + margin, 15_000_000)
        return MKCoordinateRegion(center: center, latitudinalMeters: latSpan, longitudinalMeters: lonSpan)
    }
}
