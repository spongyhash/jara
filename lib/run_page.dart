import 'dart:async';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'models.dart';
import 'widgets.dart';

enum RunState { idle, waiting, running, paused, finished }

class RunPage extends StatefulWidget {
  const RunPage({super.key});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> with WidgetsBindingObserver {
  RunState phase = RunState.idle;

  // Route is a list of segments. A new segment starts after every pause,
  // so the gap while paused is never counted as distance.
  final List<List<GpsPoint>> segments = [];
  GpsPoint? lastPoint;
  DateTime? lastTime;

  final Stopwatch stopwatch = Stopwatch();
  StreamSubscription<Position>? subscription;
  Timer? timer;

  double distanceM = 0;
  double accuracy = 99;
  bool permissionOk = true;
  bool serviceOn = true;
  bool deniedForever = false;
  bool saving = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refreshPermission();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) refreshPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    subscription?.cancel();
    timer?.cancel();
    WakelockPlus.disable();
    super.dispose();
  }

  // ---------- Permission ----------

  Future<void> refreshPermission() async {
    final enabled = await Geolocator.isLocationServiceEnabled();
    final perm = await Geolocator.checkPermission();
    if (!mounted) return;
    setState(() {
      serviceOn = enabled;
      deniedForever = perm == LocationPermission.deniedForever;
      permissionOk = enabled &&
          (perm == LocationPermission.always ||
              perm == LocationPermission.whileInUse);
    });
  }

  Future<void> allowLocation() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      await Geolocator.openLocationSettings();
      return;
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return;
    }
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    await refreshPermission();
  }

  // ---------- Run control ----------

  Future<void> startRun() async {
    await refreshPermission();
    if (!permissionOk) return;

    segments.clear();
    lastPoint = null;
    lastTime = null;
    distanceM = 0;
    accuracy = 99;
    stopwatch.reset(); // the clock starts at the first good GPS fix
    WakelockPlus.enable();

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: 3,
      intervalDuration: const Duration(seconds: 1),
    );

    subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(onPosition, onError: (Object e) {});

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    setState(() => phase = RunState.waiting);
  }

  void onPosition(Position p) {
    if (!mounted) return;
    handlePosition(p);
    setState(() {});
  }

  void handlePosition(Position p) {
    accuracy = p.accuracy;

    if (phase != RunState.waiting && phase != RunState.running) return;
    if (p.accuracy > 20) return; // skip weak GPS readings

    final pt = GpsPoint(p.latitude, p.longitude);

    if (phase == RunState.waiting) {
      stopwatch.start();
      phase = RunState.running;
    }

    final last = lastPoint;
    if (last == null) {
      // First point of the run, or first point after resuming
      segments.add([pt]);
    } else {
      final d = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        pt.latitude,
        pt.longitude,
      );
      var secs = p.timestamp.difference(lastTime ?? p.timestamp).inSeconds;
      if (secs < 1) secs = 1;

      if (d < 3) return; // ignore GPS jitter when standing still
      if (d / secs > 12) return; // ignore jumps faster than about 43 km/h

      distanceM += d;
      segments.last.add(pt);
    }

    lastPoint = pt;
    lastTime = p.timestamp;
  }

  void pauseRun() {
    stopwatch.stop();
    lastPoint = null; // next point after resume starts a new segment
    setState(() => phase = RunState.paused);
  }

  void resumeRun() {
    stopwatch.start();
    setState(() => phase = RunState.running);
  }

  void stopTracking() {
    subscription?.cancel();
    subscription = null;
    timer?.cancel();
    timer = null;
    stopwatch.stop();
    WakelockPlus.disable();
  }

  void resetRun() {
    segments.clear();
    lastPoint = null;
    lastTime = null;
    distanceM = 0;
    accuracy = 99;
    stopwatch.reset();
    setState(() {
      saving = false;
      phase = RunState.idle;
    });
  }

  void cancelWaiting() {
    stopTracking();
    resetRun();
  }

  void finishRun() {
    stopTracking();
    if (distanceM < 20) {
      resetRun();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Run too short to save')),
      );
      return;
    }
    setState(() => phase = RunState.finished);
  }

  Future<void> saveRun() async {
    if (saving) return;
    setState(() => saving = true);
    final now = DateTime.now();
    final record = RunRecord(
      now.millisecondsSinceEpoch.toString(),
      now,
      distanceM / 1000,
      stopwatch.elapsed.inSeconds,
    );
    await RunStorage.saveRun(record, segments);
    if (!mounted) return;
    resetRun();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Run saved')),
    );
  }

  Future<void> discardRun() async {
    final yes = await askYesNo(
      context,
      title: 'Discard this run?',
      message: 'This run will be deleted and cannot be recovered.',
      yes: 'Yes, discard',
      no: 'No, keep it',
    );
    if (!yes || !mounted) return;
    resetRun();
  }

  void viewMap() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => RouteMapPage(
          title: 'Your route',
          segments: List<List<GpsPoint>>.from(segments),
        ),
      ),
    );
  }

  // ---------- UI pieces ----------

  Widget metric(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 26),
        const SizedBox(height: 4),
        Text(value,
            style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w700)),
        Text(label),
      ],
    );
  }

  Widget roundButton(
      IconData icon, Color color, VoidCallback onPressed, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 112,
          height: 112,
          child: Center(
            child: SizedBox(
              width: 88,
              height: 88,
              child: FilledButton(
                onPressed: onPressed,
                style: FilledButton.styleFrom(
                  shape: const CircleBorder(),
                  backgroundColor: color,
                  padding: EdgeInsets.zero,
                ),
                child: Icon(icon, size: 44, color: Colors.white),
              ),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }

  Widget buildIdle() {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.directions_run,
              size: 80, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 8),
          const Text('Go the extra mile', style: TextStyle(fontSize: 18)),
          const SizedBox(height: 32),
          if (!permissionOk)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    const Icon(Icons.location_on, size: 36, color: Colors.blue),
                    const SizedBox(height: 8),
                    const Text('Location access needed',
                        style: TextStyle(
                            fontSize: 18, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    const Text(
                      'Jara uses your location to track your run, measure '
                      'distance and draw your route on a map.',
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: allowLocation,
                      child: Text(!serviceOn
                          ? 'Turn on location'
                          : (deniedForever ? 'Open settings' : 'Allow location')),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 64,
            child: FilledButton(
              onPressed: permissionOk ? startRun : null,
              child: const Text('Start run', style: TextStyle(fontSize: 22)),
            ),
          ),
          const SizedBox(height: 12),
          const Text('Tip: wait in the open for a stronger GPS signal.',
              style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget buildWaiting() {
    final signal =
        accuracy < 90 ? 'Signal accuracy: ${accuracy.round()} m' : 'Searching...';
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.satellite_alt,
              size: 90, color: Theme.of(context).colorScheme.primary),
          const SizedBox(height: 24),
          const Text('Waiting for GPS signal...',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          const Text('Step outside for a clearer signal if possible.',
              textAlign: TextAlign.center),
          const SizedBox(height: 12),
          Text(signal),
          const SizedBox(height: 4),
          const Text('The screen stays on while you run.',
              style: TextStyle(fontSize: 12)),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: cancelWaiting,
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  Widget buildActive() {
    final paused = phase == RunState.paused;
    final seconds = stopwatch.elapsed.inSeconds;
    final km = distanceM / 1000;
    final pace = distanceM < 20 ? '--:--' : formatPace((seconds / 60) / km);
    final gpsColor = accuracy <= 10
        ? Colors.green
        : (accuracy <= 20 ? Colors.amber : Colors.red);

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        children: [
          Row(
            children: [
              Icon(Icons.circle, size: 12, color: gpsColor),
              const SizedBox(width: 6),
              const Text('GPS'),
              const Spacer(),
              if (paused)
                const Text('PAUSED',
                    style: TextStyle(
                        color: Colors.orange, fontWeight: FontWeight.bold)),
            ],
          ),
          const Spacer(),
          FittedBox(
            child: Text(
              km.toStringAsFixed(2),
              style: const TextStyle(
                  fontSize: 110, fontWeight: FontWeight.w800, height: 1),
            ),
          ),
          const Text('km', style: TextStyle(fontSize: 28)),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              metric(Icons.timer_outlined, formatTime(seconds), 'Time'),
              metric(Icons.speed, pace, 'Pace /km'),
            ],
          ),
          const Spacer(),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              paused
                  ? roundButton(
                      Icons.play_arrow_rounded, Colors.green, resumeRun, 'Resume')
                  : roundButton(Icons.pause_rounded, Colors.amber.shade800,
                      pauseRun, 'Pause'),
              HoldButton(onComplete: finishRun),
            ],
          ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }

  Widget buildFinished() {
    final seconds = stopwatch.elapsed.inSeconds;
    final km = distanceM / 1000;
    final avgPace = formatPace((seconds / 60) / km);

    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const Spacer(),
              const CircleAvatar(
                radius: 30,
                backgroundColor: Colors.green,
                child: Icon(Icons.check, color: Colors.white, size: 36),
              ),
              const SizedBox(height: 12),
              const Text('Run Complete!',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              FittedBox(
                child: Text(
                  '${km.toStringAsFixed(2)} km',
                  style: const TextStyle(
                      fontSize: 72, fontWeight: FontWeight.w800, height: 1.1),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  metric(Icons.timer_outlined, formatTime(seconds), 'Time'),
                  metric(Icons.speed, avgPace, 'Avg pace /km'),
                ],
              ),
              const Spacer(),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: FilledButton(
                  onPressed: saving ? null : saveRun,
                  child: const Text('Save run', style: TextStyle(fontSize: 18)),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton.icon(
                  onPressed: viewMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('View map'),
                ),
              ),
              const SizedBox(height: 28),
              TextButton.icon(
                onPressed: saving ? null : discardRun,
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                icon: const Icon(Icons.delete_outline),
                label: const Text('Discard run'),
              ),
            ],
          ),
        ),
        const Positioned.fill(child: Confetti()),
      ],
    );
  }

  Widget buildBody() {
    switch (phase) {
      case RunState.idle:
        return buildIdle();
      case RunState.waiting:
        return buildWaiting();
      case RunState.running:
      case RunState.paused:
        return buildActive();
      case RunState.finished:
        return buildFinished();
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: phase == RunState.idle,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Finish or save your run first')),
          );
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Jara',
              style: TextStyle(fontWeight: FontWeight.w800)),
          actions: [
            ValueListenableBuilder<ThemeMode>(
              valueListenable: themeMode,
              builder: (context, mode, _) => IconButton(
                tooltip: 'Switch theme',
                icon: Icon(
                    mode == ThemeMode.dark ? Icons.light_mode : Icons.dark_mode),
                onPressed: toggleTheme,
              ),
            ),
          ],
        ),
        body: SafeArea(child: buildBody()),
      ),
    );
  }
}
