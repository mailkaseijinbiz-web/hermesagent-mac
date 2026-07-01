import SwiftUI
import MapKit

/// Parses `曙町 → 公園 → …` style location summaries into ordered stops.
enum LocationRouteParser {
    static func stops(from summary: String) -> [String] {
        summary.components(separatedBy: " → ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Real map with route polyline (iOS pushes coordinates to the private Mac hub).
struct LocationFootprintMapView: View {
    let points: [AppState.LocationPoint]
    var height: CGFloat = 220
    var interactionModes: MapInteractionModes = [.pan, .zoom]

    private var deduped: [AppState.LocationPoint] {
        var out: [AppState.LocationPoint] = []
        for p in points {
            if out.last?.name != p.name { out.append(p) }
        }
        return out
    }

    var body: some View {
        let coords = deduped.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        Map(initialPosition: mapPosition(for: coords), interactionModes: interactionModes) {
            if coords.count >= 2 {
                MapPolyline(coordinates: coords)
                    .stroke(.blue, lineWidth: 3)
            }
            ForEach(Array(deduped.enumerated()), id: \.element.id) { idx, p in
                Marker(markerTitle(idx: idx, name: p.name),
                       coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon))
                    .tint(p.name.contains("自宅") ? .orange : .blue)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private func markerTitle(idx: Int, name: String) -> String {
        let short = name.count > 18 ? String(name.prefix(16)) + "…" : name
        return "\(idx + 1). \(short)"
    }

    private func mapPosition(for coords: [CLLocationCoordinate2D]) -> MapCameraPosition {
        guard let first = coords.first else { return .automatic }
        if coords.count == 1 {
            return .region(MKCoordinateRegion(
                center: first,
                latitudinalMeters: 1_500,
                longitudinalMeters: 1_500
            ))
        }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for c in coords.dropFirst() {
            minLat = min(minLat, c.latitude); maxLat = max(maxLat, c.latitude)
            minLon = min(minLon, c.longitude); maxLon = max(maxLon, c.longitude)
        }
        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.012, (maxLat - minLat) * 1.55),
            longitudeDelta: max(0.012, (maxLon - minLon) * 1.55)
        )
        return .region(MKCoordinateRegion(center: center, span: span))
    }
}

/// Schematic route diagram when only place names are available (past days / no GPS sync).
struct LocationRouteDiagramView: View {
    let stops: [String]
    var maxHeight: CGFloat = 300

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(stops.enumerated()), id: \.offset) { idx, stop in
                    HStack(alignment: .top, spacing: 12) {
                        routeNode(index: idx, stop: stop, isLast: idx == stops.count - 1)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stop)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                            if stop.contains("自宅") {
                                Text("自宅")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.orange)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.top, 5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(14)
        }
        .frame(maxHeight: maxHeight)
        .background(
            LinearGradient(
                colors: [Color.blue.opacity(0.06), Color.blue.opacity(0.02)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.14), lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func routeNode(index: Int, stop: String, isLast: Bool) -> some View {
        let isHome = stop.contains("自宅")
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(isHome ? Color.orange.opacity(0.18) : Color.blue.opacity(0.14))
                    .frame(width: 30, height: 30)
                Image(systemName: isHome ? "house.fill" : "mappin.circle.fill")
                    .font(.system(size: isHome ? 13 : 15))
                    .foregroundStyle(isHome ? Color.orange : Color.blue)
            }
            if !isLast {
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.15)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: 2, height: 28)
            }
        }
        .frame(width: 30)
        .accessibilityLabel("\(index + 1)番目 \(stop)")
    }
}

/// Map when coordinates exist; otherwise a numbered route diagram from the summary text.
struct LocationDayRouteView: View {
    let summary: String
    let points: [AppState.LocationPoint]
    var mapHeight: CGFloat = 220

    private var stops: [String] { LocationRouteParser.stops(from: summary) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !points.isEmpty {
                LocationFootprintMapView(points: points, height: mapHeight)
                if stops.count >= 2 {
                    routeLegend
                }
            } else if !stops.isEmpty {
                LocationRouteDiagramView(stops: stops)
            }
        }
    }

    private var routeLegend: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(stops.enumerated()), id: \.offset) { idx, stop in
                    HStack(spacing: 4) {
                        Text("\(idx + 1)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 16, height: 16)
                            .background(Color.blue)
                            .clipShape(Circle())
                        Text(stop)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.04))
                    .clipShape(Capsule())
                    if idx < stops.count - 1 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
