import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(const MyApp());

class GpsPoint {
  final double latitude;
  final double longitude;

  GpsPoint(this.latitude, this.longitude);
}

class RunRecord {
  final DateTime date;
  final double distanceKm;
  final int seconds;

  RunRecord(this.date, this.distanceKm, this.seconds);

  double get paceMinPerKm =>
      distanceKm == 0 ? 0 : (seconds / 60) / distanceKm;

  Map<String, dynamic> toJson() => {
        'date': date.toIso8601String(),
        'distanceKm': distanceKm,
        'seconds': seconds,
      };

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
        DateTime.parse(json['date'] as String),
        (json['distanceKm'] as num).toDouble(),
        json['seconds'] as int,
      );
}

class RunStorage {
  static const String _key = 'runs';

  static Future<List<RunRecord>> loadRuns() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList(_key) ?? [];
    return list
        .map((s) => RunRecord.fromJson(jsonDecode(s) as Map<String, dynamic>))
        .toList();
  }

  static Future<void> saveRun(RunRecord run) async {
    final prefs = await SharedPreferences.getInstance();
    final list = List<String>.from(prefs.getStringList(_key) ?? []);
    list.add(jsonEncode(run.toJson()));
    await prefs.setStringList(_key, list);
  }
}

String formatTime(int totalSeconds) {
  String m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
  String s = (totalSeconds % 60).toString().padLeft(2, '0');
  return "$m:$s";
}

String formatDate(DateTime d) {
  String day = d.day.toString().padLeft(2, '0');
  String month = d.month.toString().padLeft(2, '0');
  return "$day/$month/${d.year}";
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: RunPage());
  }
}

class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> {
  final List<GpsPoint> route = [];
  final Stopwatch stopwatch = Stopwatch();
  StreamSubscription<Position>? subscription;
  Timer? timer;

  double distanceM = 0;
  DateTime? lastTime;
  bool running = false;
  String status = "Press Start to begin your run";

  Future<bool> checkPermission() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() => status = "Turn on location on your phone");
      return false;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => status = "Location permission denied");
      return false;
    }
    return true;
  }

  Future<void> startRun() async {
    if (!await checkPermission()) return;

    route.clear();
    distanceM = 0;
    lastTime = null;
    stopwatch.reset(); // the clock starts at the first good GPS fix

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 3,
      intervalDuration: const Duration(seconds: 1),
    );

    subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen((Position p) {
      // Skip weak GPS readings
      if (p.accuracy > 20) return;

      if (route.isEmpty) {
        // First good fix: start the clock
        stopwatch.start();
        status = "Running...";
      } else {
        GpsPoint last = route.last;
        double d = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          p.latitude,
          p.longitude,
        );

        int secs = p.timestamp.difference(lastTime!).inSeconds;
        if (secs < 1) secs = 1;

        if (d < 3) return; // ignore GPS jitter when standing still
        if (d / secs > 12) return; // ignore jumps faster than about 43 km/h

        distanceM += d;
      }

      route.add(GpsPoint(p.latitude, p.longitude));
      lastTime = p.timestamp;
      setState(() {});
    });

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {});
    });

    setState(() {
      running = true;
      status = "Waiting for GPS signal...";
    });
  }

  Future<void> stopRun() async {
    subscription?.cancel();
    timer?.cancel();
    stopwatch.stop();

    String message;
    if (distanceM >= 20) {
      await RunStorage.saveRun(
        RunRecord(DateTime.now(), distanceM / 1000, stopwatch.elapsed.inSeconds),
      );
      message = "Run saved";
    } else {
      message = "Run too short to save";
    }

    if (!mounted) return;
    setState(() {
      running = false;
      status = message;
    });
  }

  String paceText() {
    if (distanceM < 20) return "--";
    double minutes = stopwatch.elapsed.inSeconds / 60;
    double km = distanceM / 1000;
    return "${(minutes / km).toStringAsFixed(1)} min/km";
  }

  @override
  void dispose() {
    subscription?.cancel();
    timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Run App"),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HistoryPage()),
              );
            },
          ),
        ],
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(status),
            const SizedBox(height: 20),
            Text(
              "${(distanceM / 1000).toStringAsFixed(2)} km",
              style: const TextStyle(fontSize: 40),
            ),
            Text("Time: ${formatTime(stopwatch.elapsed.inSeconds)}"),
            Text("Pace: ${paceText()}"),
            Text("GPS points: ${route.length}"),
            const SizedBox(height: 30),
            ElevatedButton(
              onPressed: running ? stopRun : startRun,
              child: Text(running ? "Stop" : "Start"),
            ),
          ],
        ),
      ),
    );
  }
}

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<RunRecord> runs = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final loaded = await RunStorage.loadRuns();
    if (!mounted) return;
    setState(() {
      runs = loaded.reversed.toList();
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (runs.isEmpty) {
      body = const Center(child: Text("No runs yet"));
    } else {
      body = ListView.builder(
        itemCount: runs.length,
        itemBuilder: (context, i) {
          final r = runs[i];
          return ListTile(
            leading: const Icon(Icons.directions_run),
            title: Text("${r.distanceKm.toStringAsFixed(2)} km"),
            subtitle: Text(
              "${formatDate(r.date)}  |  ${formatTime(r.seconds)}  |  "
              "${r.paceMinPerKm.toStringAsFixed(1)} min/km",
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text("History")),
      body: body,
    );
  }
}