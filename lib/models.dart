import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Bumped whenever runs are saved or deleted, so History and Stats refresh.
final ValueNotifier<int> runsChanged = ValueNotifier<int>(0);

/// Light by default (easier to read in strong sun). Saved between launches.
final ValueNotifier<ThemeMode> themeMode =
    ValueNotifier<ThemeMode>(ThemeMode.light);

Future<void> loadTheme() async {
  final prefs = await SharedPreferences.getInstance();
  final dark = prefs.getBool('darkMode') ?? false;
  themeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
}

Future<void> toggleTheme() async {
  final dark = themeMode.value != ThemeMode.dark;
  themeMode.value = dark ? ThemeMode.dark : ThemeMode.light;
  final prefs = await SharedPreferences.getInstance();
  await prefs.setBool('darkMode', dark);
}

class GpsPoint {
  final double latitude;
  final double longitude;

  GpsPoint(this.latitude, this.longitude);

  LatLng toLatLng() => LatLng(latitude, longitude);
}

class RunRecord {
  final String id;
  final DateTime date;
  final double distanceKm;
  final int seconds;

  RunRecord(this.id, this.date, this.distanceKm, this.seconds);

  double get paceMinPerKm =>
      distanceKm == 0 ? 0 : (seconds / 60) / distanceKm;

  Map<String, dynamic> toJson() => {
        'id': id,
        'date': date.toIso8601String(),
        'distanceKm': distanceKm,
        'seconds': seconds,
      };

  factory RunRecord.fromJson(Map<String, dynamic> json) {
    final date = DateTime.parse(json['date'] as String);
    return RunRecord(
      (json['id'] as String?) ?? date.millisecondsSinceEpoch.toString(),
      date,
      (json['distanceKm'] as num).toDouble(),
      json['seconds'] as int,
    );
  }
}

class RunStorage {
  static const String _key = 'runs';

  static double _round(double v) => (v * 100000).round() / 100000;

  static Future<List<RunRecord>> loadRuns() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
        final runs = list
        .map((s) => RunRecord.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
    runs.sort((a, b) => a.date.compareTo(b.date)); // oldest first
    return runs;
  }

  /// Saves the run summary, and the route under its own key so the
  /// History list stays fast to load.
  static Future<void> saveRun(
      RunRecord run, List<List<GpsPoint>> segments) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_key) ?? []);
    list.add(jsonEncode(run.toJson()));
    await prefs.setStringList(_key, list);

    final routeData = segments
        .map((seg) =>
            seg.map((p) => [_round(p.latitude), _round(p.longitude)]).toList())
        .toList();
    await prefs.setString('route_${run.id}', jsonEncode(routeData));
    runsChanged.value++;
  }

  static Future<List<List<GpsPoint>>> loadRoute(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('route_$id');
    if (text == null) return [];
    final data = jsonDecode(text) as List<dynamic>;
    return data.map((seg) {
      return (seg as List<dynamic>).map((pt) {
        final xy = pt as List<dynamic>;
        return GpsPoint((xy[0] as num).toDouble(), (xy[1] as num).toDouble());
      }).toList();
    }).toList();
  }

  static Future<void> deleteRun(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_key) ?? []);
    list.removeWhere((s) {
      final r = RunRecord.fromJson(jsonDecode(s) as Map<String, dynamic>);
      return r.id == id;
    });
    await prefs.setStringList(_key, list);
    await prefs.remove('route_$id');
    runsChanged.value++;
  }
}

String formatTime(int totalSeconds) {
  final h = totalSeconds ~/ 3600;
  final m = ((totalSeconds % 3600) ~/ 60).toString().padLeft(2, '0');
  final s = (totalSeconds % 60).toString().padLeft(2, '0');
  return h > 0 ? '$h:$m:$s' : '$m:$s';
}

/// Pace as minutes:seconds per km, for example 6:15
String formatPace(double minPerKm) {
  if (!minPerKm.isFinite || minPerKm <= 0) return '--:--';
  final total = (minPerKm * 60).round();
  final m = total ~/ 60;
  final s = (total % 60).toString().padLeft(2, '0');
  return '$m:$s';
}

String formatDate(DateTime d) {
  final day = d.day.toString().padLeft(2, '0');
  final month = d.month.toString().padLeft(2, '0');
  return '$day/$month/${d.year}';
}

/// The runner's display name, from sign-up. Falls back to part of the email.
String userName() {
  final user = Supabase.instance.client.auth.currentUser;
  final name = user?.userMetadata?['display_name'];
  if (name is String && name.trim().isNotEmpty) return name.trim();
  final email = user?.email;
  if (email != null && email.contains('@')) return email.split('@').first;
  return 'runner';
}

/// A short message for the Run Complete screen, based on distance.
String praise(double km) {
  final name = userName();
  if (km >= 10) return 'Incredible, $name!';
  if (km >= 5) return 'Strong run, $name!';
  if (km >= 2) return 'Nice run, $name!';
  return 'Good start, $name!';
}