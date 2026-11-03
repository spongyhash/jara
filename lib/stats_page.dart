import 'dart:math';
import 'package:flutter/material.dart';
import 'models.dart';

class StatsPage extends StatefulWidget {
  const StatsPage({super.key});

  @override
  State<StatsPage> createState() => _StatsPageState();
}

class _StatsPageState extends State<StatsPage> {
  List<RunRecord> runs = [];

  @override
  void initState() {
    super.initState();
    load();
    runsChanged.addListener(load);
  }

  @override
  void dispose() {
    runsChanged.removeListener(load);
    super.dispose();
  }

  Future<void> load() async {
    final loaded = await RunStorage.loadRuns();
    if (!mounted) return;
    setState(() => runs = loaded);
  }

  Widget card(IconData icon, String value, String label) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 22),
            const SizedBox(height: 4),
            FittedBox(
              child: Text(value,
                  style: const TextStyle(
                      fontSize: 24, fontWeight: FontWeight.w700)),
            ),
            Text(label, style: const TextStyle(fontSize: 12)),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (runs.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Stats')),
        body: const Center(child: Text('Save a run to see your stats')),
      );
    }

    final totalKm = runs.fold<double>(0, (s, r) => s + r.distanceKm);
    final totalSec = runs.fold<int>(0, (s, r) => s + r.seconds);
    final avgPace = totalKm == 0 ? 0.0 : (totalSec / 60) / totalKm;
    final longest = runs.map((r) => r.distanceKm).reduce(max);

    // Fastest pace, ignoring very short runs
    final eligible = runs.where((r) => r.distanceKm >= 0.5).toList();
    final bestPace = eligible.isEmpty
        ? 0.0
        : eligible.map((r) => r.paceMinPerKm).reduce(min);

    // Last 7 days, oldest first
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final days = [for (int i = 6; i >= 0; i--) today.subtract(Duration(days: i))];
    final dayKm = days.map((day) {
      return runs
          .where((r) =>
              r.date.year == day.year &&
              r.date.month == day.month &&
              r.date.day == day.day)
          .fold<double>(0, (s, r) => s + r.distanceKm);
    }).toList();
    final weekKm = dayKm.fold<double>(0, (s, k) => s + k);
    final maxKm = max(1.0, dayKm.reduce(max));

    return Scaffold(
      appBar: AppBar(title: const Text('Stats')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          GridView.count(
            crossAxisCount: 2,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            childAspectRatio: 1.5,
            children: [
              card(Icons.directions_run, '${runs.length}', 'Runs'),
              card(Icons.route, '${totalKm.toStringAsFixed(1)} km', 'Total distance'),
              card(Icons.timer_outlined, formatTime(totalSec), 'Total time'),
              card(Icons.speed, formatPace(avgPace), 'Average pace /km'),
              card(Icons.bolt, formatPace(bestPace), 'Best pace /km'),
              card(Icons.emoji_events_outlined,
                  '${longest.toStringAsFixed(2)} km', 'Longest run'),
            ],
          ),
          const SizedBox(height: 16),
          Text('Last 7 days: ${weekKm.toStringAsFixed(1)} km',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          SizedBox(
            height: 130,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                for (int i = 0; i < 7; i++)
                  Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(dayKm[i] == 0 ? '' : dayKm[i].toStringAsFixed(1),
                          style: const TextStyle(fontSize: 11)),
                      const SizedBox(height: 2),
                      Container(
                        width: 28,
                        height: 6 + (dayKm[i] / maxKm) * 80,
                        decoration: BoxDecoration(
                          color: dayKm[i] == 0
                              ? Colors.grey.withAlpha(80)
                              : Theme.of(context).colorScheme.primary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text('MTWTFSS'[days[i].weekday - 1]),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
