import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'grid.dart';
import 'models.dart';
import 'news.dart';
import 'offline_map.dart';

/// Who owns a cell right now, as reported by the server.
class CellInfo {
  final String ownerName;
  final int strength;
  final bool mine;

  /// When this was fetched, in milliseconds since 1970 (for the offline cache).
  final int fetchedAt;

  const CellInfo(this.ownerName, this.strength, this.mine, this.fetchedAt);
}

/// The Territory tab's map. It shows:
/// - you, as a moving blue dot (the camera follows you)
/// - cells owned by you (green) and by rivals (orange), stronger = darker
/// - during a run: your trail, and the cells you have touched so far (blue)
/// - a banner when you step into a new cell
class TerritoryMap extends StatefulWidget {
  /// True when this tab is on screen (saves battery when it is not).
  final bool active;
  final bool running;
  final bool paused;
  final bool permissionOk;
  final int gpsStage;
  final List<List<GpsPoint>> route;

  /// Latest position from the run itself, used while running.
  final LatLng? runPosition;

  /// Shown at the top (run numbers) and bottom (buttons).
  final Widget? hud;
  final Widget? controls;

  const TerritoryMap({
    super.key,
    required this.active,
    required this.running,
    required this.paused,
    required this.permissionOk,
    required this.gpsStage,
    required this.route,
    required this.runPosition,
    this.hud,
    this.controls,
  });

  @override
  State<TerritoryMap> createState() => _TerritoryMapState();
}

class _TerritoryMapState extends State<TerritoryMap> {
  static const LatLng _fallback = LatLng(6.5244, 3.3792);

  final MapController controller = MapController();
  StreamSubscription<Position>? sub;
  Timer? debounce;
  Timer? refresh;
  Timer? bannerTimer;

  bool ready = false;
  bool follow = true;
  bool tooFar = false;
  bool offline = false;
  int unseen = 0; // attacks on your cells you have not looked at yet
  DateTime? updatedAt; // when the cells on screen were last fetched

  LatLng? me; // position when no run is in progress
  LatLng? lastShown;
  String? currentCell;
  String? banner;

  final Map<String, CellInfo> cells = {};
  List<Polygon> cellPolys = [];
  List<Polygon> touchedPolys = [];
  int touchedCount = -1;

  LatLng? get position => widget.running ? widget.runPosition : me;

  @override
  void initState() {
    super.initState();
    loadCache();
    loadUnseen();
    updateStream();
    refresh = Timer.periodic(const Duration(seconds: 30), (_) {
      if (widget.active) {
        fetchCells();
        loadUnseen();
      }
    });
  }

  @override
  void didUpdateWidget(TerritoryMap old) {
    super.didUpdateWidget(old);
    updateStream();
    if (widget.running && !old.running) currentCell = null;
    final pos = position;
    if (pos != null && pos != lastShown) {
      lastShown = pos;
      onNewPosition(pos);
    }
  }

  @override
  void dispose() {
    sub?.cancel();
    debounce?.cancel();
    refresh?.cancel();
    bannerTimer?.cancel();
    super.dispose();
  }

  // ---------- Your position ----------

  /// While no run is in progress, a light GPS stream moves the blue dot.
  /// During a run, the run supplies the position instead.
  void updateStream() {
    final want = widget.active && widget.permissionOk && !widget.running;
    if (want && sub == null) {
      final settings = AndroidSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 5,
        forceLocationManager: widget.gpsStage >= 1,
      );
      sub = Geolocator.getPositionStream(locationSettings: settings).listen(
        (p) {
          if (!mounted || p.accuracy > 60 || p.isMocked) return;
          final pos = LatLng(p.latitude, p.longitude);
          setState(() => me = pos);
          lastShown = pos;
          onNewPosition(pos);
        },
        onError: (Object e) {},
      );
    } else if (!want && sub != null) {
      sub!.cancel();
      sub = null;
    }
  }

  void onNewPosition(LatLng pos) {
    // Wait until the current frame is drawn before moving the camera
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (follow && ready) {
        controller.move(pos, controller.camera.zoom);
      }
      if (widget.running) enteredCell(pos);
    });
  }

  void enteredCell(LatLng pos) {
    final id = HexGrid.cellId(pos.latitude, pos.longitude);
    if (id == currentCell) return;
    currentCell = id;

    final info = cells[id];
    String text;
    if (info == null) {
      text = 'Free cell';
    } else if (info.mine) {
      text = 'Your cell, strength ${info.strength}';
    } else {
      text = '${info.ownerName}\'s cell, strength ${info.strength}';
    }

    HapticFeedback.lightImpact();
    setState(() => banner = text);
    bannerTimer?.cancel();
    bannerTimer = Timer(const Duration(seconds: 4), () {
      if (mounted) setState(() => banner = null);
    });
  }

  Future<void> loadUnseen() async {
    try {
      final n = await unseenNewsCount();
      if (mounted) setState(() => unseen = n);
    } catch (_) {
      // offline: keep the last count
    }
  }

  // ---------- Cells from the server ----------

  void scheduleFetch() {
    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 700), fetchCells);
  }

  Future<void> fetchCells() async {
    if (!mounted || !ready) return;
    final camera = controller.camera;

    // Only draw cells when zoomed in enough to keep the phone fast
    if (camera.zoom < 15) {
      if (!tooFar) setState(() => tooFar = true);
      return;
    }
    final b = camera.visibleBounds;
    final ids = HexGrid.cellsInBounds(b.south, b.west, b.north, b.east);
    if (ids == null) {
      if (!tooFar) setState(() => tooFar = true);
      return;
    }
    if (tooFar) setState(() => tooFar = false);

    try {
      final rows = await Supabase.instance.client
          .rpc('cells_for', params: {'p_ids': ids.toList()});
      if (!mounted) return;
      final now = DateTime.now();
      for (final id in ids) {
        cells.remove(id);
      }
      for (final r in rows as List<dynamic>) {
        cells[r['cell_id'] as String] = CellInfo(
          r['owner_name'] as String,
          (r['strength'] as num).toInt(),
          r['mine'] as bool,
          now.millisecondsSinceEpoch,
        );
      }
      setState(() {
        offline = false;
        updatedAt = now;
        cellPolys = buildCellPolys();
      });
      saveCache();
    } catch (_) {
      if (mounted) setState(() => offline = true);
    }
  }

  // ---------- Saved copy of the last cells (for when you are offline) ----------

  Future<void> loadCache() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('cell_cache');
    if (text == null) return;
    try {
      final data = jsonDecode(text) as Map<String, dynamic>;
      final cutoff = DateTime.now()
          .subtract(const Duration(days: 14))
          .millisecondsSinceEpoch;
      var newest = 0;
      data.forEach((id, v) {
        final a = v as List<dynamic>; // [owner, strength, mine, fetchedAt]
        final t = (a[3] as num).toInt();
        if (t >= cutoff) {
          cells[id] = CellInfo(
            a[0] as String,
            (a[1] as num).toInt(),
            a[2] as bool,
            t,
          );
          if (t > newest) newest = t;
        }
      });
      if (!mounted) return;
      setState(() {
        if (newest > 0 && updatedAt == null) {
          updatedAt = DateTime.fromMillisecondsSinceEpoch(newest);
        }
        cellPolys = buildCellPolys();
      });
    } catch (_) {
      // A damaged cache is simply ignored
    }
  }

  Future<void> saveCache() async {
    final prefs = await SharedPreferences.getInstance();
    var entries = cells.entries.toList();
    if (entries.length > 2000) {
      entries.sort((a, b) => b.value.fetchedAt.compareTo(a.value.fetchedAt));
      entries = entries.sublist(0, 2000);
    }
    final data = {
      for (final e in entries)
        e.key: [
          e.value.ownerName,
          e.value.strength,
          e.value.mine,
          e.value.fetchedAt,
        ],
    };
    await prefs.setString('cell_cache', jsonEncode(data));
  }

  String updatedText() {
    final d = updatedAt;
    if (d == null) return 'Offline';
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    final sameDay = DateTime.now().difference(d).inHours < 24 &&
        DateTime.now().day == d.day;
    return sameDay
        ? 'Offline: cells as of $h:$m'
        : 'Offline: cells as of ${formatDate(d)} $h:$m';
  }

  List<Polygon> buildCellPolys() {
    final list = <Polygon>[];
    cells.forEach((id, info) {
      final base = info.mine ? Colors.green : Colors.deepOrange;
      final alpha = (50 + info.strength * 1.2).clamp(50, 170).toInt();
      list.add(Polygon(
        points: HexGrid.boundary(id),
        color: base.withAlpha(alpha),
        borderColor: base,
        borderStrokeWidth: 1.5,
      ));
    });
    return list;
  }

  void showCellInfo(LatLng point) {
    final id = HexGrid.cellId(point.latitude, point.longitude);
    final info = cells[id];
    String text;
    if (info == null) {
      text = 'Free cell. Run through it on a territory run to claim it.';
    } else if (info.mine) {
      text = 'Your cell, strength ${info.strength} of 100';
    } else {
      text = '${info.ownerName}\'s cell, strength ${info.strength}. '
          'Run through it to weaken it.';
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  // ---------- Drawing ----------

  Widget pill(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: const TextStyle(
            color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pos = position;

    // Cells touched so far in this run (shown as pending until the server
    // confirms them after you finish)
    final touched =
        widget.running ? HexGrid.cellsTouched(widget.route) : <String>{};
    if (touched.length != touchedCount) {
      touchedCount = touched.length;
      touchedPolys = [
        for (final id in touched)
          Polygon(
            points: HexGrid.boundary(id),
            color: Colors.blue.withAlpha(30),
            borderColor: Colors.blue,
            borderStrokeWidth: 3,
          ),
      ];
    }

    final lines = [
      for (final s in widget.route)
        if (s.length > 1)
          Polyline(
            points: s.map((g) => g.toLatLng()).toList(),
            strokeWidth: 5,
            color: Colors.blue,
          ),
    ];

    return Stack(
      children: [
        FlutterMap(
          mapController: controller,
          options: MapOptions(
            initialCenter: pos ?? _fallback,
            initialZoom: 16,
            minZoom: 3,
            maxZoom: 19,
            onMapReady: () {
              ready = true;
              final p = position;
              if (p != null) controller.move(p, 16);
              scheduleFetch();
            },
            onPositionChanged: (camera, hasGesture) {
              if (hasGesture && follow) setState(() => follow = false);
              scheduleFetch();
            },
            onTap: (tapPosition, point) => showCellInfo(point),
          ),
          children: [
            BaseMapLayer(
              around: pos ?? _fallback,
              dark: Theme.of(context).brightness == Brightness.dark,
            ),
            PolygonLayer(polygons: [...cellPolys, ...touchedPolys]),
            PolylineLayer(polylines: lines),
            if (pos != null)
              MarkerLayer(
                markers: [
                  Marker(
                    point: pos,
                    width: 30,
                    height: 30,
                    child: const _BlueDot(),
                  ),
                ],
              ),
            const RichAttributionWidget(
              attributions: [
                TextSourceAttribution('OpenStreetMap contributors'),
              ],
            ),
          ],
        ),

        // Top: mode, legend, notices, banner, run numbers
        Positioned(
          top: 8,
          left: 8,
          right: 8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  pill('TERRITORY WAR', Colors.deepOrange),
                  pill('Yours', Colors.green),
                  pill('Rivals', Colors.deepOrange.shade300),
                  if (widget.running) pill('This run', Colors.blue),
                ],
              ),
              if (tooFar)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: pill('Zoom in to see territory', Colors.black87),
                ),
              if (offline)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: pill(updatedText(), Colors.black87),
                ),
              if (banner != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Card(
                    elevation: 6,
                    color: Colors.black87,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      child: Text(
                        'Entering: $banner',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700),
                      ),
                    ),
                  ),
                ),
              if (widget.hud != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: widget.hud!,
                ),
            ],
          ),
        ),

        // Side buttons: territory news, and re-centre
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Badge(
                  isLabelVisible: unseen > 0,
                  label: Text('$unseen'),
                  child: FloatingActionButton.small(
                    heroTag: null,
                    onPressed: () async {
                      await showNews(context);
                      if (mounted) setState(() => unseen = 0);
                    },
                    child: const Icon(Icons.notifications_outlined),
                  ),
                ),
                const SizedBox(height: 10),
                FloatingActionButton.small(
                  heroTag: null,
                  onPressed: () {
                    setState(() => follow = true);
                    final p = position;
                    if (p != null && ready) controller.move(p, 17);
                  },
                  child: Icon(
                      follow ? Icons.my_location : Icons.location_searching),
                ),
              ],
            ),
          ),
        ),

        // Bottom: Start button, or the run controls
        if (widget.controls != null)
          Positioned(
            left: 10,
            right: 10,
            bottom: 10,
            child: widget.controls!,
          ),
      ],
    );
  }
}

class _BlueDot extends StatelessWidget {
  const _BlueDot();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.blue,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 3),
        boxShadow: const [BoxShadow(blurRadius: 6, color: Colors.black38)],
      ),
    );
  }
}
