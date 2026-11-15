import 'dart:math';
import 'dart:ui' as ui;
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:geolocator/geolocator.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'models.dart';

class _Palette {
  final List<Color> gradient;
  final Color accent;
  final Color text;
  final Color panel;

  const _Palette(this.gradient, this.accent, this.text, this.panel);
}

const List<String> styleNames = ['Sunrise', 'Dusk', 'Clean'];

const List<_Palette> _palettes = [
  // Sunrise
  _Palette(
    [Color(0xFF141A33), Color(0xFF5B2E4A), Color(0xFFE8702A)],
    Color(0xFFFF9A2E),
    Colors.white,
    Color(0x44000000),
  ),
  // Dusk
  _Palette(
    [Color(0xFF0A1128), Color(0xFF1F3A93), Color(0xFFFF7E67)],
    Color(0xFF5CB0FF),
    Colors.white,
    Color(0x44000000),
  ),
  // Clean (white, good for printing or bright screens)
  _Palette(
    [Color(0xFFFFFFFF), Color(0xFFEAF5EE)],
    Color(0xFF008751),
    Color(0xFF14231A),
    Color(0x22008751),
  ),
];

String runTitle(DateTime d) {
  final h = d.hour;
  if (h < 5) return 'Night Run';
  if (h < 12) return 'Morning Run';
  if (h < 17) return 'Afternoon Run';
  if (h < 21) return 'Evening Run';
  return 'Night Run';
}

String clockText(DateTime d) {
  final h = d.hour.toString().padLeft(2, '0');
  final m = d.minute.toString().padLeft(2, '0');
  return '$h:$m';
}

/// Removes the first and last [meters] of a route, so a shared picture does
/// not show where the run started (often home). Very short routes return
/// nothing, because there would be nothing left to show.
List<List<GpsPoint>> trimRouteEnds(List<List<GpsPoint>> segments,
    {double meters = 150}) {
  final segs = [for (final s in segments) List<GpsPoint>.from(s)];
  segs.removeWhere((s) => s.isEmpty);

  var total = 0.0;
  for (final s in segs) {
    for (var i = 1; i < s.length; i++) {
      total += Geolocator.distanceBetween(
        s[i - 1].latitude,
        s[i - 1].longitude,
        s[i].latitude,
        s[i].longitude,
      );
    }
  }
  if (total < meters * 3) return [];

  _trimStart(segs, meters);

  final reversed = [for (final s in segs.reversed) s.reversed.toList()];
  _trimStart(reversed, meters);
  return [for (final s in reversed.reversed) s.reversed.toList()];
}

void _trimStart(List<List<GpsPoint>> segs, double meters) {
  var left = meters;
  while (segs.isNotEmpty && left > 0) {
    final s = segs.first;
    while (s.length > 1 && left > 0) {
      left -= Geolocator.distanceBetween(
        s[0].latitude,
        s[0].longitude,
        s[1].latitude,
        s[1].longitude,
      );
      s.removeAt(0);
    }
    if (left > 0) {
      segs.removeAt(0);
    } else {
      break;
    }
  }
}

/// The picture that gets shared. Fixed 360 x 450 (4:5), captured at 3x
/// so the saved image is 1080 x 1350.
class RunShareCard extends StatelessWidget {
  final RunRecord run;
  final List<List<GpsPoint>> segments;
  final int style;

  const RunShareCard({
    super.key,
    required this.run,
    required this.segments,
    required this.style,
  });

  @override
  Widget build(BuildContext context) {
    final p = _palettes[style];
    final hasRoute = segments.any((s) => s.length > 1);
    final speed = run.seconds == 0
        ? '--'
        : (run.distanceKm / (run.seconds / 3600)).toStringAsFixed(1);

    Widget stat(String value, String label) {
      return Expanded(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FittedBox(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 11, color: p.text.withAlpha(190))),
          ],
        ),
      );
    }

    return SizedBox(
      width: 360,
      height: 450,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: p.gradient,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(22),
          child: DefaultTextStyle.merge(
            style: TextStyle(color: p.text),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.directions_run, color: p.accent, size: 26),
                    const SizedBox(width: 6),
                    const Text('Jara',
                        style: TextStyle(
                            fontSize: 22, fontWeight: FontWeight.w800)),
                    const Spacer(),
                    const Text('Run Summary', style: TextStyle(fontSize: 12)),
                  ],
                ),
                const SizedBox(height: 18),
                Text(
                  runTitle(run.date),
                  style: TextStyle(
                    fontSize: 18,
                    fontStyle: FontStyle.italic,
                    color: p.accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                FittedBox(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.baseline,
                    textBaseline: TextBaseline.alphabetic,
                    children: [
                      Text(
                        run.distanceKm.toStringAsFixed(2),
                        style: const TextStyle(
                            fontSize: 84, fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(width: 6),
                      const Text('km',
                          style: TextStyle(
                              fontSize: 30, fontWeight: FontWeight.w700)),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Row(
                    children: [
                      stat(formatTime(run.seconds), 'Time'),
                      stat(formatPace(run.paceMinPerKm), 'Pace min/km'),
                      stat(speed, 'Speed km/h'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: hasRoute
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(16),
                            child: CustomPaint(
                              painter: RoutePainter(segments, p.accent, p.text),
                            ),
                          )
                        : const Center(
                            child: Text('Go the extra mile',
                                style: TextStyle(
                                    fontStyle: FontStyle.italic, fontSize: 16)),
                          ),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 14),
                    const SizedBox(width: 6),
                    Text('${formatDate(run.date)}  ${clockText(run.date)}',
                        style: const TextStyle(fontSize: 13)),
                    const Spacer(),
                    const Text('Go the extra mile',
                        style: TextStyle(
                            fontSize: 12, fontStyle: FontStyle.italic)),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Draws the route outline (no map tiles, so it works offline).
class RoutePainter extends CustomPainter {
  final List<List<GpsPoint>> segments;
  final Color lineColor;
  final Color borderColor;

  RoutePainter(this.segments, this.lineColor, this.borderColor);

  @override
  void paint(Canvas canvas, Size size) {
    final all = [for (final s in segments) ...s];
    if (all.length < 2) return;

    var minLat = all.first.latitude, maxLat = all.first.latitude;
    var minLng = all.first.longitude, maxLng = all.first.longitude;
    for (final p in all) {
      minLat = min(minLat, p.latitude);
      maxLat = max(maxLat, p.latitude);
      minLng = min(minLng, p.longitude);
      maxLng = max(maxLng, p.longitude);
    }

    // Shrink longitude so the shape is not stretched sideways
    final lngScale = cos(((minLat + maxLat) / 2) * pi / 180);
    final w = (maxLng - minLng) * lngScale;
    final h = maxLat - minLat;

    const pad = 16.0;
    final availW = size.width - pad * 2;
    final availH = size.height - pad * 2;
    final scaleW = w <= 0 ? double.infinity : availW / w;
    final scaleH = h <= 0 ? double.infinity : availH / h;
    final scale = min(scaleW, scaleH);
    if (!scale.isFinite) return;

    final offX = pad + (availW - w * scale) / 2;
    final offY = pad + (availH - h * scale) / 2;

    Offset toOffset(GpsPoint p) => Offset(
          offX + (p.longitude - minLng) * lngScale * scale,
          offY + (maxLat - p.latitude) * scale,
        );

    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 9
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = lineColor.withAlpha(60);
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = lineColor;

    for (final s in segments) {
      if (s.length < 2) continue;
      final first = toOffset(s.first);
      final path = Path()..moveTo(first.dx, first.dy);
      for (var i = 1; i < s.length; i++) {
        final o = toOffset(s[i]);
        path.lineTo(o.dx, o.dy);
      }
      canvas.drawPath(path, glow);
      canvas.drawPath(path, line);
    }

    void dot(Offset o, Color color) {
      canvas.drawCircle(o, 7, Paint()..color = color);
      canvas.drawCircle(
        o,
        7,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = borderColor,
      );
    }

    dot(toOffset(all.first), Colors.green);
    dot(toOffset(all.last), Colors.red);
  }

  @override
  bool shouldRepaint(covariant RoutePainter old) => true;
}

/// Shows the card, lets you pick a style, then shares it as a picture.
class SharePreviewPage extends StatefulWidget {
  final RunRecord run;
  final List<List<GpsPoint>> segments;

  const SharePreviewPage({
    super.key,
    required this.run,
    required this.segments,
  });

  @override
  State<SharePreviewPage> createState() => _SharePreviewPageState();
}

class _SharePreviewPageState extends State<SharePreviewPage> {
  final GlobalKey cardKey = GlobalKey();
  int style = 0;
  bool busy = false;
  bool hideEnds = true;

  @override
  void initState() {
    super.initState();
    loadPrivacy();
  }

  Future<void> loadPrivacy() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('hideRouteEnds') ?? true;
    if (!mounted) return;
    setState(() => hideEnds = value);
  }

  Future<void> share() async {
    setState(() => busy = true);
    try {
      final boundary =
          cardKey.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 3);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final bytes = data!.buffer.asUint8List();

      final km = widget.run.distanceKm.toStringAsFixed(2);
      await SharePlus.instance.share(
        ShareParams(
          text: 'I ran $km km with Jara. You can try it out too',
          files: [XFile.fromData(bytes, mimeType: 'image/png')],
          fileNameOverrides: ['jara_run.png'],
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not share this run')),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final shown =
        hideEnds ? trimRouteEnds(widget.segments) : widget.segments;
    return Scaffold(
      appBar: AppBar(title: const Text('Share run')),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: FittedBox(
                    child: RepaintBoundary(
                      key: cardKey,
                      child: RunShareCard(
                        run: widget.run,
                        segments: shown,
                        style: style,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            if (hideEnds && widget.segments.any((s) => s.length > 1))
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text('Start and end of your route are hidden',
                    style: TextStyle(fontSize: 12)),
              ),
            Wrap(
              spacing: 8,
              children: [
                for (int i = 0; i < styleNames.length; i++)
                  ChoiceChip(
                    label: Text(styleNames[i]),
                    selected: style == i,
                    onSelected: (_) => setState(() => style = i),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 54,
                child: FilledButton.icon(
                  onPressed: busy ? null : share,
                  icon: const Icon(Icons.share),
                  label: Text(busy ? 'Preparing...' : 'Share'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
