import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'grid.dart';
import 'models.dart';
import 'offline_map.dart';

/// Yes/No confirmation. Tapping outside the dialog counts as No.
Future<bool> askYesNo(
  BuildContext context, {
  required String title,
  required String message,
  String yes = 'Yes',
  String no = 'No',
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(no),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          child: Text(yes),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// Round red stop button: press and hold for 2 seconds to complete.
class HoldButton extends StatefulWidget {
  final VoidCallback onComplete;
  final String label;

  const HoldButton({
    super.key,
    required this.onComplete,
    this.label = 'Hold 2s to end',
  });

  @override
  State<HoldButton> createState() => _HoldButtonState();
}

class _HoldButtonState extends State<HoldButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller =
        AnimationController(vsync: this, duration: const Duration(seconds: 2));
    controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        controller.reset();
        HapticFeedback.heavyImpact();
        widget.onComplete();
      }
    });
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Listener(
          onPointerDown: (_) => controller.forward(),
          onPointerUp: (_) => controller.reverse(),
          onPointerCancel: (_) => controller.reverse(),
          child: AnimatedBuilder(
            animation: controller,
            builder: (context, _) {
              return SizedBox(
                width: 112,
                height: 112,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: 112,
                      height: 112,
                      child: CircularProgressIndicator(
                        value: controller.value,
                        strokeWidth: 8,
                        color: Colors.orange,
                        backgroundColor: Colors.red.withAlpha(60),
                      ),
                    ),
                    Container(
                      width: 88,
                      height: 88,
                      decoration: const BoxDecoration(
                        color: Colors.red,
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.stop_rounded,
                          color: Colors.white, size: 44),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 6),
        Text(widget.label, style: const TextStyle(fontSize: 12)),
      ],
    );
  }
}

class _Piece {
  final double x;
  final double speed;
  final double size;
  final double phase;
  final Color color;

  _Piece(this.x, this.speed, this.size, this.phase, this.color);
}

/// A small, light confetti burst (26 pieces, about 3 seconds).
class Confetti extends StatefulWidget {
  const Confetti({super.key});

  @override
  State<Confetti> createState() => _ConfettiState();
}

class _ConfettiState extends State<Confetti>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late final List<_Piece> pieces;

  @override
  void initState() {
    super.initState();
    const colors = [
      Colors.green,
      Colors.blue,
      Colors.orange,
      Colors.pink,
      Colors.amber,
    ];
    final rnd = Random();
    pieces = List.generate(26, (i) {
      return _Piece(
        rnd.nextDouble(),
        0.6 + rnd.nextDouble() * 0.6,
        6 + rnd.nextDouble() * 6,
        rnd.nextDouble() * 6.28,
        colors[i % colors.length],
      );
    });
    controller = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2800))
      ..forward();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: controller,
        builder: (context, _) => SizedBox.expand(
          child: CustomPaint(painter: _ConfettiPainter(pieces, controller.value)),
        ),
      ),
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  final List<_Piece> pieces;
  final double t;

  _ConfettiPainter(this.pieces, this.t);

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in pieces) {
      final y = -20 + t * p.speed * (size.height + 40);
      final x = p.x * size.width + sin(t * 8 + p.phase) * 18;
      final alpha = (255 * (1 - t)).clamp(0, 255).toInt();
      final paint = Paint()..color = p.color.withAlpha(alpha);
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(t * 6 + p.phase);
      canvas.drawRect(
        Rect.fromLTWH(-p.size / 2, -p.size / 2, p.size, p.size * 0.6),
        paint,
      );
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _ConfettiPainter old) => true;
}

/// Draws a run's route on an OpenStreetMap map. Paused gaps stay as gaps.
class RouteMap extends StatelessWidget {
  final List<List<GpsPoint>> segments;
  final bool showCells;

  const RouteMap({super.key, required this.segments, this.showCells = false});

  @override
  Widget build(BuildContext context) {
    final all = <LatLng>[
      for (final s in segments)
        for (final g in s) g.toLatLng(),
    ];

    if (all.isEmpty) {
      return const Center(child: Text('No route saved for this run'));
    }

    final lines = [
      for (final s in segments)
        if (s.length > 1)
          Polyline(
            points: s.map((g) => g.toLatLng()).toList(),
            strokeWidth: 5,
            color: Colors.blue,
          ),
    ];

    final cells = showCells ? HexGrid.cellsForRoute(segments) : <String>{};
    final polygons = [
      for (final id in cells)
        Polygon(
          points: HexGrid.boundary(id),
          color: Colors.green.withAlpha(45),
          borderColor: Colors.green,
          borderStrokeWidth: 1.5,
        ),
    ];

    return FlutterMap(
      options: MapOptions(
        initialCenter: all.first,
        initialZoom: 16,
        initialCameraFit: all.length > 1
            ? CameraFit.bounds(
                bounds: LatLngBounds.fromPoints(all),
                padding: const EdgeInsets.all(48),
              )
            : null,
      ),
      children: [
        BaseMapLayer(
          around: all.first,
          dark: Theme.of(context).brightness == Brightness.dark,
        ),
        if (polygons.isNotEmpty) PolygonLayer(polygons: polygons),
        PolylineLayer(polylines: lines),
        MarkerLayer(
          markers: [
            Marker(
              point: all.first,
              width: 24,
              height: 24,
              child: const Icon(Icons.circle, color: Colors.green, size: 22),
            ),
            Marker(
              point: all.last,
              width: 32,
              height: 32,
              child: const Icon(Icons.flag, color: Colors.red, size: 30),
            ),
          ],
        ),
        const RichAttributionWidget(
          attributions: [TextSourceAttribution('OpenStreetMap contributors')],
        ),
      ],
    );
  }
}

class RouteMapPage extends StatelessWidget {
  final String title;
  final List<List<GpsPoint>> segments;
  final bool showCells;

  const RouteMapPage({
    super.key,
    required this.title,
    required this.segments,
    this.showCells = false,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: RouteMap(segments: segments, showCells: showCells),
    );
  }
}

/// Tells the runner what the server decided about their run's territory.
void showClaimResult(BuildContext context, Map<String, dynamic> r) {
  final status = r['status'] as String? ?? 'error';
  int n(String key) => (r[key] as num?)?.toInt() ?? 0;

  String title = 'Territory update';
  String body;

  switch (status) {
    case 'claimed':
      final lines = <String>[
        if (n('claimed') > 0) 'New cells claimed: ${n('claimed')}',
        if (n('captured') > 0) 'Taken from rivals: ${n('captured')}',
        if (n('hit') > 0) 'Rival cells weakened: ${n('hit')}',
        if (n('defended') > 0) 'Your cells defended: ${n('defended')}',
      ];
      body = lines.isEmpty
          ? 'No new territory this time. You already ran these cells today.'
          : lines.join('\n');
      title = 'Territory update';
      break;
    case 'rejected_mocked':
      title = 'Run not counted';
      body = 'Fake GPS was detected, so this run does not count for territory.';
      break;
    case 'rejected_speed':
      title = 'Run not counted';
      body = 'This run looked too fast for walking or running, so it does '
          'not count for territory.';
      break;
    case 'rejected_time_mismatch':
    case 'rejected_distance_mismatch':
      title = 'Run not counted';
      body = 'We could not verify this run\'s route and timing, so it does '
          'not count for territory.';
      break;
    case 'rejected_no_times':
    case 'rejected_no_route':
      title = 'Run not counted';
      body = 'This run has no route details, so it cannot count for territory.';
      break;
    case 'rejected_date':
      title = 'Run not counted';
      body = 'This run is too old to count for territory.';
      break;
    case 'rejected_mode':
      title = 'Free run';
      body = 'This was a free run, so it does not count for territory.';
      break;
    case 'too_short':
      title = 'Run too short';
      body = 'Territory needs at least 1 km and 5 minutes. Keep going next time!';
      break;
    case 'no_zone':
      title = 'Outside the launch areas';
      body = 'No territory was claimed because this run was outside the '
          'launch areas.';
      break;
    case 'capped':
      title = 'Daily limit reached';
      body = 'You have reached today\'s territory limit. Come back tomorrow!';
      break;
    default:
      title = 'Territory not updated';
      body = 'Something went wrong: ${r['detail'] ?? status}';
  }

  showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(body),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('OK'),
        ),
      ],
    ),
  );
}
