import 'dart:math';
import 'package:latlong2/latlong.dart';
import 'models.dart';
import 'share_card.dart' show trimRouteEnds;

/// The Jara territory grid: pointy-top hexagons on a flat (Web Mercator) map.
///
/// A cell id looks like "412:-37". The same formulas can be repeated on the
/// server, so the phone and the server always agree which cell a point is in.
class HexGrid {
  /// Centre of a cell to its corner, in metres. Gives cells about 130 m wide
  /// (flat side to flat side), close to 15,000 square metres each.
  static const double size = 75;

  static const double _earthRadius = 6378137;

  static double _mx(double lng) => _earthRadius * lng * pi / 180;
  static double _my(double lat) =>
      _earthRadius * log(tan(pi / 4 + lat * pi / 360));
  static double _lng(double x) => x / _earthRadius * 180 / pi;
  static double _lat(double y) =>
      (2 * atan(exp(y / _earthRadius)) - pi / 2) * 180 / pi;

  /// Which cell a position is in.
  static String cellId(double lat, double lng) {
    final x = _mx(lng);
    final y = _my(lat);

    final qf = (sqrt(3) / 3 * x - y / 3) / size;
    final rf = (2 / 3 * y) / size;
    final sf = -qf - rf;

    // Round to the nearest hexagon
    var q = qf.round();
    var r = rf.round();
    final s = sf.round();
    final dq = (q - qf).abs();
    final dr = (r - rf).abs();
    final ds = (s - sf).abs();
    if (dq > dr && dq > ds) {
      q = -r - s;
    } else if (dr > ds) {
      r = -q - s;
    }
    return '$q:$r';
  }

  /// The six corners of a cell, for drawing it on the map.
  static List<LatLng> boundary(String id) {
    final parts = id.split(':');
    final q = int.parse(parts[0]);
    final r = int.parse(parts[1]);
    final cx = size * sqrt(3) * (q + r / 2);
    final cy = size * 1.5 * r;

    final corners = <LatLng>[];
    for (var i = 0; i < 6; i++) {
      final angle = (60 * i - 30) * pi / 180;
      corners.add(LatLng(
        _lat(cy + size * sin(angle)),
        _lng(cx + size * cos(angle)),
      ));
    }
    return corners;
  }

  /// The cells a run counts for.
  /// - The first and last 150 m are left out, so the map never shows where
  ///   someone starts (often home). Routes under about 450 m count for nothing.
  /// - A cell needs at least 2 good GPS points inside it, so brushing past
  ///   a corner does not claim it.
  /// - The cells holding the start and finish points are never claimed.
  static Set<String> cellsForRoute(List<List<GpsPoint>> segments) {
    final trimmed = trimRouteEnds(segments);
    final counts = <String, int>{};
    for (final seg in trimmed) {
      for (final p in seg) {
        final id = cellId(p.latitude, p.longitude);
        counts[id] = (counts[id] ?? 0) + 1;
      }
    }
    final result = {
      for (final e in counts.entries)
        if (e.value >= 2) e.key,
    };

    // Never claim the cells that hold the start and finish points, because
    // a cell someone owns every day would show roughly where they live.
    final firstSeg = segments.firstWhere((s) => s.isNotEmpty,
        orElse: () => <GpsPoint>[]);
    final lastSeg = segments.lastWhere((s) => s.isNotEmpty,
        orElse: () => <GpsPoint>[]);
    if (firstSeg.isNotEmpty) {
      result.remove(cellId(firstSeg.first.latitude, firstSeg.first.longitude));
    }
    if (lastSeg.isNotEmpty) {
      result.remove(cellId(lastSeg.last.latitude, lastSeg.last.longitude));
    }
    return result;
  }

  /// Every cell touched by the route so far, with no trimming. Used for the
  /// live "this run" highlight on the map (the server decides what counts).
  static Set<String> cellsTouched(List<List<GpsPoint>> segments) {
    return {
      for (final s in segments)
        for (final p in s) cellId(p.latitude, p.longitude),
    };
  }

  /// The ids of all cells inside a map view, or null if there are too many
  /// (zoomed out too far to draw them quickly).
  static Set<String>? cellsInBounds(
    double south,
    double west,
    double north,
    double east, {
    int maxCells = 900,
  }) {
    final midLat = (south + north) / 2;
    final dLat = 60 / 111320; // about 60 m, small enough to hit every cell
    final dLng = 60 / (111320 * cos(midLat * pi / 180));
    final out = <String>{};
    for (var lat = south - dLat; lat <= north + dLat; lat += dLat) {
      for (var lng = west - dLng; lng <= east + dLng; lng += dLng) {
        out.add(cellId(lat, lng));
        if (out.length > maxCells) return null;
      }
    }
    return out;
  }
}
