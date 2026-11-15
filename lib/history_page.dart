import 'package:flutter/material.dart';
import 'models.dart';
import 'share_card.dart';
import 'sync.dart';
import 'widgets.dart';

class HistoryPage extends StatefulWidget {
  const HistoryPage({super.key});

  @override
  State<HistoryPage> createState() => _HistoryPageState();
}

class _HistoryPageState extends State<HistoryPage> {
  List<RunRecord> runs = [];
  bool loading = true;
  bool syncing = false;

  @override
  void initState() {
    super.initState();
    load();
    runsChanged.addListener(load);
    SyncService.syncAll(); // quietly sync when the app opens
  }

  @override
  void dispose() {
    runsChanged.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final loaded = await RunStorage.loadRuns();
    if (!mounted) return;
    setState(() {
      runs = loaded.reversed.toList();
      loading = false;
    });
  }

  Future<void> sync() async {
    if (syncing) return;
    setState(() => syncing = true);
    final message = await SyncService.syncAll();
    if (!mounted) return;
    setState(() => syncing = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (loading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (runs.isEmpty) {
      body = const Center(child: Text('No runs yet. Go for your first run!'));
    } else {
      body = ListView.builder(
        itemCount: runs.length,
        itemBuilder: (context, i) {
          final r = runs[i];
          return ListTile(
            leading: Icon(r.mode == 'territory'
                ? Icons.flag_outlined
                : Icons.directions_run),
            title: Text('${r.distanceKm.toStringAsFixed(2)} km'),
            subtitle: Text(
              '${formatDate(r.date)}  |  ${formatTime(r.seconds)}  |  '
              '${formatPace(r.paceMinPerKm)} min/km',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => RunDetailPage(run: r)),
              );
            },
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('History'),
        actions: [
          IconButton(
            tooltip: 'Sync runs',
            onPressed: syncing ? null : sync,
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.cloud_sync_outlined),
          ),
        ],
      ),
      body: body,
    );
  }
}

class RunDetailPage extends StatefulWidget {
  final RunRecord run;

  const RunDetailPage({super.key, required this.run});

  @override
  State<RunDetailPage> createState() => _RunDetailPageState();
}

class _RunDetailPageState extends State<RunDetailPage> {
  List<List<GpsPoint>>? segments;

  @override
  void initState() {
    super.initState();
    loadRoute();
  }

  Future<void> loadRoute() async {
    final route = await RunStorage.loadRoute(widget.run.id);
    if (!mounted) return;
    setState(() => segments = route);
  }

  Future<void> deleteRun() async {
    final yes = await askYesNo(
      context,
      title: 'Delete this run?',
      message: 'This run and its route will be deleted for good.',
      yes: 'Yes, delete',
      no: 'No, keep it',
    );
    if (!yes) return;
    await SyncService.deleteRun(widget.run.id);
    if (!mounted) return;
    Navigator.pop(context);
  }

  void shareRun() {
    final route = segments;
    if (route == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SharePreviewPage(run: widget.run, segments: route),
      ),
    );
  }

  Widget stat(String value, String label) {
    return Column(
      children: [
        Text(value,
            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w700)),
        Text(label),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.run;
    return Scaffold(
      appBar: AppBar(
        title: Text(formatDate(r.date)),
        actions: [
          IconButton(
            tooltip: 'Share run',
            icon: const Icon(Icons.share),
            onPressed: segments == null ? null : shareRun,
          ),
          IconButton(
            tooltip: 'Delete run',
            icon: const Icon(Icons.delete_outline),
            onPressed: deleteRun,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: segments == null
                ? const Center(child: CircularProgressIndicator())
                : RouteMap(
                    segments: segments!,
                    showCells: widget.run.mode == 'territory',
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                stat('${r.distanceKm.toStringAsFixed(2)} km', 'Distance'),
                stat(formatTime(r.seconds), 'Time'),
                stat(formatPace(r.paceMinPerKm), 'Pace (min/km)'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
