import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'grid.dart';
import 'models.dart';
import 'profile_page.dart';
import 'share_card.dart';
import 'sync.dart';
import 'territory_map.dart';
import 'widgets.dart';

enum RunState { idle, waiting, running, paused, finished }

class RunPage extends StatefulWidget {
  /// false = the free run tab, true = the territory war tab
  final bool territory;

  /// True while this tab is on screen (the map saves battery when it is not).
  final bool visible;

  const RunPage({super.key, this.territory = false, this.visible = true});

  @override
  State<RunPage> createState() => _RunPageState();
}

class _RunPageState extends State<RunPage> with WidgetsBindingObserver {
  /// A GPS reading is used only if the phone says it is accurate to this
  /// many metres or better. Weaker readings are still counted on screen.
  static const double maxAccuracyM = 30;

  String get modeName => widget.territory ? 'territory' : 'free';

  RunState phase = RunState.idle;

  // Route is a list of segments. A new segment starts after every pause,
  // so the gap while paused is never counted as distance.
  final List<List<GpsPoint>> segments = [];
  GpsPoint? lastPoint;
  DateTime? lastTime;

  final Stopwatch stopwatch = Stopwatch();
  StreamSubscription<Position>? subscription;
  Timer? timer;
  Timer? gpsWatchdog;

  double distanceM = 0;
  double accuracy = 99;
  bool permissionOk = true;
  bool serviceOn = true;
  bool deniedForever = false;
  String permText = '?';
  bool saving = false;
  bool sawMocked = false;

  /// Latest usable position, for the blue dot on the territory map.
  LatLng? livePos;

  // GPS diagnostics
  int readings = 0;
  String? gpsError;

  /// How we ask Android for location:
  /// 0 = standard, 1 = Android's own location manager (some phones need it),
  /// 2 = the same without the running notification.
  /// If nothing arrives, the app tries the next one by itself and
  /// remembers the one that worked.
  int gpsStage = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    refreshPermission();
    loadStage();
  }

  Future<void> loadStage() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() => gpsStage = prefs.getInt('gpsStage') ?? 0);
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
    gpsWatchdog?.cancel();
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
      permText = perm.name;
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

  // ---------- GPS stream ----------

  void listenToGps() {
    subscription?.cancel();

    const notification = ForegroundNotificationConfig(
      notificationTitle: 'Jara',
      notificationText: 'Run in progress',
      notificationChannelName: 'Run tracking',
      enableWakeLock: true,
    );

    final settings = AndroidSettings(
      accuracy: LocationAccuracy.best,
      distanceFilter: gpsStage == 0 ? 3 : 0,
      intervalDuration: const Duration(seconds: 1),
      forceLocationManager: gpsStage >= 1,
      foregroundNotificationConfig: gpsStage >= 2 ? null : notification,
    );

    subscription = Geolocator.getPositionStream(locationSettings: settings)
        .listen(onPosition, onError: (Object e) {
      if (!mounted) return;
      setState(() => gpsError = e.toString());
    });
  }

  /// If no reading arrives for 15 seconds, try the next GPS method.
  void startWatchdog() {
    gpsWatchdog?.cancel();
    gpsWatchdog = Timer.periodic(const Duration(seconds: 15), (t) {
      if (!mounted ||
          phase != RunState.waiting ||
          readings > 0 ||
          gpsStage >= 2) {
        t.cancel();
        return;
      }
      gpsStage++;
      listenToGps();
      setState(() {});
    });
  }

  Future<void> rememberStage() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('gpsStage', gpsStage);
  }

  // ---------- Run control ----------

  Future<void> startRun() async {
    await refreshPermission();
    if (!mounted || !permissionOk) return;
    if (activeRunMode.value != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Another run is already in progress')),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    gpsStage = prefs.getInt('gpsStage') ?? 0;

    segments.clear();
    lastPoint = null;
    lastTime = null;
    distanceM = 0;
    accuracy = 99;
    readings = 0;
    gpsError = null;
    sawMocked = false;
    stopwatch.reset(); // the clock starts at the first good GPS fix
    WakelockPlus.enable();

    listenToGps();
    startWatchdog();

    timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });

    activeRunMode.value = modeName;
    setState(() => phase = RunState.waiting);
  }

  void onPosition(Position p) {
    if (!mounted) return;
    handlePosition(p);
    setState(() {});
  }

  void handlePosition(Position p) {
    readings++;
    if (readings == 1) rememberStage();
    accuracy = p.accuracy;

    if (p.isMocked) {
      sawMocked = true;
      return; // fake GPS readings never count
    }

    if (p.accuracy <= 50) livePos = LatLng(p.latitude, p.longitude);

    if (phase != RunState.waiting && phase != RunState.running) return;
    if (p.accuracy > maxAccuracyM) return; // skip weak GPS readings

    final pt = GpsPoint(
      p.latitude,
      p.longitude,
      p.timestamp.millisecondsSinceEpoch ~/ 1000,
    );

    if (phase == RunState.waiting) {
      stopwatch.start();
      phase = RunState.running;
    }

    final last = lastPoint;
    if (last == null) {
      // First point of the run, or first point after resuming
      segments.add([pt]);
    } else {
      // If the phone reports speed, near zero means you are standing still
      if (p.speedAccuracy > 0 && p.speed < 0.3) return;

      final d = Geolocator.distanceBetween(
        last.latitude,
        last.longitude,
        pt.latitude,
        pt.longitude,
      );
      var secs = p.timestamp.difference(lastTime ?? p.timestamp).inSeconds;
      if (secs < 1) secs = 1;

      // Movement smaller than the GPS error is just noise. The weaker the
      // signal, the more movement is needed before it counts.
      if (d < max(3, p.accuracy * 0.5)) return;
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
    gpsWatchdog?.cancel();
    gpsWatchdog = null;
    stopwatch.stop();
    WakelockPlus.disable();
  }

  void resetRun() {
    activeRunMode.value = null;
    livePos = null;
    segments.clear();
    lastPoint = null;
    lastTime = null;
    distanceM = 0;
    accuracy = 99;
    sawMocked = false;
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
      mocked: sawMocked,
      mode: modeName,
    );
    await RunStorage.saveRun(record, segments);
    if (widget.territory) {
      syncAndReport(); // upload and claim territory in the background
    } else {
      SyncService.syncAll(); // upload in the background
    }
    if (!mounted) return;
    resetRun();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Run saved')),
    );
  }

  /// Uploads the run, lets the server judge it, then shows the verdict.
  Future<void> syncAndReport() async {
    SyncService.lastClaim = null;
    await SyncService.syncAll();
    final claim = SyncService.lastClaim;
    if (!mounted || claim == null) return;
    showClaimResult(context, claim);
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
          showCells: widget.territory,
        ),
      ),
    );
  }

  void shareRun() {
    final now = DateTime.now();
    final record = RunRecord(
      now.millisecondsSinceEpoch.toString(),
      now,
      distanceM / 1000,
      stopwatch.elapsed.inSeconds,
    );
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SharePreviewPage(
          run: record,
          segments: List<List<GpsPoint>>.from(segments),
        ),
      ),
    );
  }

  // ---------- Territory tab: the live map ----------

  Widget buildTerritoryIdle() {
    return TerritoryMap(
      active: widget.visible,
      running: false,
      paused: false,
      permissionOk: permissionOk,
      gpsStage: gpsStage,
      route: const <List<GpsPoint>>[],
      runPosition: null,
      controls: territoryStartPanel(),
    );
  }

  Widget territoryStartPanel() {
    const accent = Colors.deepOrange;
    return Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!permissionOk) ...[
              const Text('Location access needed',
                  style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              const Text(
                'Jara uses your location to show you on the map and track '
                'your run.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: allowLocation,
                child: Text(!serviceOn
                    ? 'Turn on location'
                    : (deniedForever ? 'Open settings' : 'Allow location')),
              ),
              const SizedBox(height: 10),
            ],
            ValueListenableBuilder<String?>(
              valueListenable: activeRunMode,
              builder: (context, active, _) {
                final busy = active != null;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: FilledButton(
                        style: FilledButton.styleFrom(backgroundColor: accent),
                        onPressed: (permissionOk && !busy) ? startRun : null,
                        child: const Text('Start territory run',
                            style: TextStyle(fontSize: 20)),
                      ),
                    ),
                    if (busy)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'A ${active == 'territory' ? 'territory' : 'free'} '
                          'run is already in progress.',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 6),
            const Text(
              'Counts when you cover at least 1 km. The first and last '
              '150 m are never claimed.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget buildTerritoryActive() {
    final paused = phase == RunState.paused;
    final seconds = stopwatch.elapsed.inSeconds;
    final km = distanceM / 1000;
    final pace = distanceM < 20 ? '--:--' : formatPace((seconds / 60) / km);

    final hud = Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${km.toStringAsFixed(2)} km',
                    style: const TextStyle(
                        fontSize: 34, fontWeight: FontWeight.w800)),
                paused
                    ? const Text('PAUSED',
                        style: TextStyle(
                            color: Colors.orange, fontWeight: FontWeight.bold))
                    : const Text('This run'),
              ],
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(formatTime(seconds),
                    style: const TextStyle(
                        fontSize: 22, fontWeight: FontWeight.w700)),
                Text('$pace min/km'),
              ],
            ),
          ],
        ),
      ),
    );

    final controls = Card(
      elevation: 6,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
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
      ),
    );

    return TerritoryMap(
      active: widget.visible,
      running: true,
      paused: paused,
      permissionOk: permissionOk,
      gpsStage: gpsStage,
      route: segments,
      runPosition: livePos,
      hud: hud,
      controls: controls,
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
    final accent =
        widget.territory ? Colors.deepOrange : Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // The mode this tab starts, shown clearly before every run
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withAlpha(40),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              widget.territory ? 'TERRITORY WAR' : 'FREE RUN',
              style: TextStyle(
                color: accent,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Icon(widget.territory ? Icons.flag : Icons.directions_run,
              size: 80, color: accent),
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: profileChanged,
            builder: (context, _, __) => Text('Hi, ${userName()}',
                style:
                    const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Text(
            widget.territory
                ? 'Claim cells, defend them, and take them from rivals.'
                : 'Just you and the road. No territory and no rivals.',
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16),
          ),
          if (widget.territory) ...[
            const SizedBox(height: 12),
            const Text(
              'A territory run counts when you cover at least 1 km. The first '
              'and last 150 m are never claimed.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ],
          const SizedBox(height: 28),
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
          ValueListenableBuilder<String?>(
            valueListenable: activeRunMode,
            builder: (context, active, _) {
              final busy = active != null;
              return Column(
                children: [
                  SizedBox(
                    width: double.infinity,
                    height: 64,
                    child: FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: accent),
                      onPressed: (permissionOk && !busy) ? startRun : null,
                      child: Text(
                        widget.territory
                            ? 'Start territory run'
                            : 'Start free run',
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  ),
                  if (busy)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(
                        'A ${active == 'territory' ? 'territory' : 'free'} '
                        'run is already in progress.',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          const Text('Tip: wait in the open for a stronger GPS signal.',
              style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }

  Widget buildWaiting() {
    final details = [
      'Readings received: $readings',
      if (readings > 0)
        'Last accuracy: ${accuracy.round()} m '
            '(need ${maxAccuracyM.round()} m or better)',
      'GPS method: ${gpsStage + 1} of 3',
      'Permission: $permText',
      if (!serviceOn) 'Phone location switch is OFF',
      if (gpsError != null) 'Problem: $gpsError',
    ].join('\n');

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
          Text(details, textAlign: TextAlign.center),
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
              const SizedBox(width: 14),
              Text(
                widget.territory ? 'TERRITORY RUN' : 'FREE RUN',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  color: widget.territory ? Colors.deepOrange : null,
                ),
              ),
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
              metric(Icons.speed, pace, 'Pace (min/km)'),
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
              Text(praise(km),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      fontSize: 28, fontWeight: FontWeight.bold)),
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
                  metric(Icons.speed, avgPace, 'Avg pace (min/km)'),
                ],
              ),
              if (widget.territory) ...[
                const SizedBox(height: 12),
                Text(
                  'Territory cells covered: '
                  '${HexGrid.cellsForRoute(segments).length}',
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w600),
                ),
              ],
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
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: viewMap,
                        icon: const Icon(Icons.map_outlined),
                        label: const Text('View map'),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: SizedBox(
                      height: 52,
                      child: OutlinedButton.icon(
                        onPressed: shareRun,
                        icon: const Icon(Icons.share),
                        label: const Text('Share'),
                      ),
                    ),
                  ),
                ],
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
        return widget.territory ? buildTerritoryIdle() : buildIdle();
      case RunState.waiting:
        return buildWaiting();
      case RunState.running:
      case RunState.paused:
        return widget.territory ? buildTerritoryActive() : buildActive();
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
          title: Text(widget.territory ? 'Territory war' : 'Jara',
              style: const TextStyle(fontWeight: FontWeight.w800)),
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
