import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vector_map_tiles/vector_map_tiles.dart';
import 'package:vector_map_tiles_pmtiles/vector_map_tiles_pmtiles.dart';

/// The map files that ship inside the app (see assets/maps/).
/// Each one covers a box on the map. Inside a box, the map works with no
/// internet at all. Outside every box, the app falls back to online tiles.
class OfflineMaps {
  /// Which map file covers this point, or null if none does.
  /// These boxes match the ones used to make the files.
  static String? fileFor(LatLng p) {
    final lat = p.latitude;
    final lng = p.longitude;
    if (lat >= 6.40 && lat <= 6.54 && lng >= 3.32 && lng <= 3.60) {
      return 'lagos'; // Island and Mainland launch areas
    }
    if (lat >= 10.57 && lat <= 10.67 && lng >= 7.39 && lng <= 7.50) {
      return 'test'; // developer test area
    }
    return null;
  }

  static final Map<String, Future<PmTilesVectorTileProvider?>> _providers = {};

  static Future<PmTilesVectorTileProvider?> provider(String name) {
    return _providers.putIfAbsent(name, () async {
      try {
        final path = await _copyToPhone(name);
        return await PmTilesVectorTileProvider.fromSource(path);
      } catch (_) {
        return null; // any problem means we use the online map instead
      }
    });
  }

  /// The tile reader needs a real file, not an app asset, so the file is
  /// copied into the phone's storage once (and again if it ever changes).
  static Future<String> _copyToPhone(String name) async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/$name.pmtiles');
    final data = await rootBundle.load('assets/maps/$name.pmtiles');
    if (!await file.exists() || await file.length() != data.lengthInBytes) {
      await file.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    return file.path;
  }
}

/// The picture under everything else on a map: the offline map when there is
/// a file for this place, otherwise the online map.
class BaseMapLayer extends StatefulWidget {
  final LatLng around;
  final bool dark;

  const BaseMapLayer({super.key, required this.around, required this.dark});

  @override
  State<BaseMapLayer> createState() => _BaseMapLayerState();
}

class _BaseMapLayerState extends State<BaseMapLayer> {
  Future<PmTilesVectorTileProvider?>? future;
  String? file;

  @override
  void initState() {
    super.initState();
    choose();
  }

  @override
  void didUpdateWidget(BaseMapLayer old) {
    super.didUpdateWidget(old);
    choose();
  }

  void choose() {
    final name = OfflineMaps.fileFor(widget.around);
    if (future == null || name != file) {
      file = name;
      future = name == null
          ? Future<PmTilesVectorTileProvider?>.value(null)
          : OfflineMaps.provider(name);
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<PmTilesVectorTileProvider?>(
      future: future,
      builder: (context, snapshot) {
        final provider = snapshot.data;
        if (provider == null) {
          // No offline file for this place, or it is still loading
          return TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'ng.jara.app',
          );
        }
        return VectorTileLayer(
          key: ValueKey('$file-${widget.dark}'),
          theme: widget.dark ? ProtomapsThemes.dark() : ProtomapsThemes.light(),
          tileProviders: TileProviders({'protomaps': provider}),
        );
      },
    );
  }
}
