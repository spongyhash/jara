import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';

/// Local-first sync: runs always save on the phone first, then this copies
/// them to the cloud (and brings back any runs the phone is missing).
class SyncService {
  static bool _running = false;
  static const String _pendingKey = 'pending_deletes';

  static SupabaseClient get _db => Supabase.instance.client;

  static bool get loggedIn => _db.auth.currentUser != null;

  /// Returns a short message describing what happened.
  static Future<String> syncAll() async {
    if (!loggedIn) return 'Log in to sync your runs';
    if (_running) return 'Sync already in progress';
    _running = true;
    try {
      return await _sync().timeout(const Duration(seconds: 90));
    } catch (e) {
      return 'Could not sync. Check your internet and try again.';
    } finally {
      _running = false;
    }
  }

  static Future<String> _sync() async {
    final prefs = await SharedPreferences.getInstance();
    final userId = _db.auth.currentUser!.id;

    // 1. Deletes that could not reach the cloud earlier
    final pending = List<String>.from(prefs.getStringList(_pendingKey) ?? []);
    for (final id in List<String>.from(pending)) {
      await _db.from('runs').delete().eq('user_id', userId).eq('local_id', id);
      pending.remove(id);
      await prefs.setStringList(_pendingKey, pending);
    }

    // 2. What the cloud already has (summaries only, no routes)
    final cloudRows = await _db
        .from('runs')
        .select('local_id, run_date, distance_km, seconds')
        .eq('user_id', userId);
    final cloudIds = {for (final r in cloudRows) r['local_id'] as String};

    final localRuns = await RunStorage.loadRuns();
    final localIds = {for (final r in localRuns) r.id};

    // 3. Upload runs the cloud does not have yet
    var uploaded = 0;
    for (final run in localRuns) {
      if (cloudIds.contains(run.id)) continue;
      final routeText = prefs.getString('route_${run.id}');
      await _db.from('runs').upsert(
        {
          'user_id': userId,
          'local_id': run.id,
          'run_date': run.date.toUtc().toIso8601String(),
          'distance_km': run.distanceKm,
          'seconds': run.seconds,
          'route': routeText == null ? null : jsonDecode(routeText),
        },
        onConflict: 'user_id,local_id',
      );
      uploaded++;
    }

    // 4. Download runs that exist only in the cloud (new phone, reinstall)
    final missing =
        cloudRows.where((r) => !localIds.contains(r['local_id'])).toList();
    var downloaded = 0;
    if (missing.isNotEmpty) {
      final ids = missing.map((r) => r['local_id'] as String).toList();
      final routeRows = await _db
          .from('runs')
          .select('local_id, route')
          .eq('user_id', userId)
          .inFilter('local_id', ids);
      final routes = {
        for (final r in routeRows) r['local_id'] as String: r['route'],
      };

      // 'runs' is the same key RunStorage uses
      final list = List<String>.from(prefs.getStringList('runs') ?? []);
      for (final r in missing) {
        final id = r['local_id'] as String;
        final record = RunRecord(
          id,
          DateTime.parse(r['run_date'] as String).toLocal(),
          (r['distance_km'] as num).toDouble(),
          (r['seconds'] as num).toInt(),
        );
        list.add(jsonEncode(record.toJson()));
        final route = routes[id];
        if (route != null) {
          await prefs.setString('route_$id', jsonEncode(route));
        }
        downloaded++;
      }
      await prefs.setStringList('runs', list);
      runsChanged.value++;
    }

    if (uploaded == 0 && downloaded == 0) return 'Everything is up to date';
    return 'Synced: $uploaded uploaded, $downloaded downloaded';
  }

  /// Deletes a run on the phone, then in the cloud. If the phone is offline,
  /// the delete is remembered and sent at the next sync.
  static Future<void> deleteRun(String id) async {
    await RunStorage.deleteRun(id);
    if (!loggedIn) return;
    final userId = _db.auth.currentUser!.id;
    try {
      await _db
          .from('runs')
          .delete()
          .eq('user_id', userId)
          .eq('local_id', id)
          .timeout(const Duration(seconds: 15));
    } catch (_) {
      final prefs = await SharedPreferences.getInstance();
      final pending =
          List<String>.from(prefs.getStringList(_pendingKey) ?? []);
      if (!pending.contains(id)) pending.add(id);
      await prefs.setStringList(_pendingKey, pending);
    }
  }
}
