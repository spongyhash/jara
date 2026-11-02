import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

void main() => runApp(const MyApp());

class GpsPoint {
  final double latitude;
  final double longitude;

  GpsPoint(this.latitude, this.longitude);
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
    stopwatch.reset();
    stopwatch.start();

    const settings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 5, // only update after moving 5 metres
    );

    subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen((Position p) {
      if (p.accuracy > 25) return; // ignore poor GPS readings

      if (route.isNotEmpty) {
        GpsPoint last = route.last;
        distanceM += Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          p.latitude,
          p.longitude,
        );
      }
      route.add(GpsPoint(p.latitude, p.longitude));
      setState(() {});
    });

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {});
    });

    setState(() {
      running = true;
      status = "Running...";
    });
  }

  void stopRun() {
    subscription?.cancel();
    timer?.cancel();
    stopwatch.stop();
    setState(() {
      running = false;
      status = "Run finished";
    });
  }

  String formatTime(int totalSeconds) {
    String m = (totalSeconds ~/ 60).toString().padLeft(2, '0');
    String s = (totalSeconds % 60).toString().padLeft(2, '0');
    return "$m:$s";
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
      appBar: AppBar(title: const Text("Run App")),
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