import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: LocationPage());
  }
}

class LocationPage extends StatefulWidget {
  const LocationPage({super.key});

  @override
  State<LocationPage> createState() => _LocationPageState();
}

class _LocationPageState extends State<LocationPage> {
  String message = "Tap the button to get your location";

  Position? currentPosition;
  
  Future<void> getLocation() async {
    bool enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      setState(() => message = "Turn on location on your phone");
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    if (permission == LocationPermission.denied ||
        permission == LocationPermission.deniedForever) {
      setState(() => message = "Location permission denied");
      return;
    }

    Position p = await Geolocator.getCurrentPosition();
    setState(() {
  currentPosition = p;

  message = "Lat: ${p.latitude.toStringAsFixed(5)}\n"
      "Lng: ${p.longitude.toStringAsFixed(5)}";
});
  }

  Future<void> openMap() async {
    if (currentPosition == null) return;

    final lat = currentPosition!.latitude;
    final lng = currentPosition!.longitude;

    final uri = Uri.parse(
      'https://www.google.com/maps/search/?api=1&query=$lat,$lng',
    );

    final opened = await launchUrl(
      uri,
      mode: LaunchMode.externalApplication,
    );

    if (!opened && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not open Google Maps'),
        ),
      );
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Run App")),
      body: Center(
  child: Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        message,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: 20),
      ElevatedButton.icon(
        onPressed: currentPosition == null ? null : openMap,
        icon: const Icon(Icons.map),
        label: const Text('Open in Google Maps'),
      ),
    ],
  ),
),
            floatingActionButton: FloatingActionButton(
        onPressed: getLocation,
        child: const Icon(Icons.my_location),
      ),
    );
  }
}