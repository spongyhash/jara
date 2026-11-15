import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Territory fights from the last 7 days, newest first.
Future<List<Map<String, dynamic>>> fetchNews() async {
  final rows = await Supabase.instance.client
      .rpc('my_news', params: {'p_days': 7});
  return [
    for (final r in rows as List<dynamic>) Map<String, dynamic>.from(r as Map),
  ];
}

/// How many attacks on your cells you have not looked at yet.
Future<int> unseenNewsCount() async {
  final prefs = await SharedPreferences.getInstance();
  final seen = prefs.getInt('newsSeenAt') ?? 0;
  var count = 0;
  for (final r in await fetchNews()) {
    final at = DateTime.parse(r['last_at'] as String).millisecondsSinceEpoch;
    if (r['against_me'] == true && at > seen) {
      count += (r['n'] as num).toInt();
    }
  }
  return count;
}

String _ago(DateTime t) {
  final d = DateTime.now().difference(t);
  if (d.inMinutes < 1) return 'just now';
  if (d.inMinutes < 60) return '${d.inMinutes} min ago';
  if (d.inHours < 24) return '${d.inHours} h ago';
  return '${d.inDays} d ago';
}

String _line(Map<String, dynamic> r) {
  final name = r['other_name'] as String;
  final n = (r['n'] as num).toInt();
  final cells = n == 1 ? '1 cell' : '$n cells';
  final capture = r['kind'] == 'capture';
  if (r['against_me'] == true) {
    return capture
        ? '$name took $cells from you'
        : '$name weakened $cells of yours';
  }
  return capture
      ? 'You took $cells from $name'
      : 'You weakened $cells of $name\'s';
}

/// A sheet listing recent territory fights. Opening it marks them as seen.
Future<void> showNews(BuildContext context) async {
  List<Map<String, dynamic>> rows = [];
  String? error;
  try {
    rows = await fetchNews();
  } catch (_) {
    error = 'Could not load territory news. Check your internet.';
  }

  final prefs = await SharedPreferences.getInstance();
  await prefs.setInt('newsSeenAt', DateTime.now().millisecondsSinceEpoch);

  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      Widget body;
      if (error != null) {
        body = Padding(
          padding: const EdgeInsets.all(24),
          child: Text(error),
        );
      } else if (rows.isEmpty) {
        body = const Padding(
          padding: EdgeInsets.all(24),
          child: Text('No territory news yet. Claim cells, then defend them!'),
        );
      } else {
        body = ListView(
          shrinkWrap: true,
          children: [
            for (final r in rows)
              ListTile(
                leading: Icon(
                  r['against_me'] == true
                      ? Icons.warning_amber_rounded
                      : Icons.flag,
                  color: r['against_me'] == true
                      ? Colors.deepOrange
                      : Colors.green,
                ),
                title: Text(_line(r)),
                subtitle: Text(
                    _ago(DateTime.parse(r['last_at'] as String).toLocal())),
              ),
          ],
        );
      }
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('Territory news',
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            ),
            Flexible(child: body),
          ],
        ),
      );
    },
  );
}
