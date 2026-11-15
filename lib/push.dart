import 'dart:async';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Lets push code show a message from anywhere in the app.
final GlobalKey<ScaffoldMessengerState> messengerKey =
    GlobalKey<ScaffoldMessengerState>();

/// Push notifications through Firebase Cloud Messaging.
/// Firebase only delivers the alert. Your data stays in Supabase.
/// If anything about Firebase is not set up, push quietly stays off and the
/// rest of the app is unaffected.
class Push {
  static bool _ready = false;
  static StreamSubscription<String>? _refreshSub;
  static StreamSubscription<RemoteMessage>? _foregroundSub;

  static Future<void> init() async {
    try {
      await Firebase.initializeApp();
      _ready = true;

      // While the app is open, show alerts as a small message at the bottom.
      // When the app is closed, the phone shows them itself.
      _foregroundSub = FirebaseMessaging.onMessage.listen((message) {
        final n = message.notification;
        if (n == null) return;
        final text = [
          if (n.title != null) n.title!,
          if (n.body != null) n.body!,
        ].join(': ');
        messengerKey.currentState?.showSnackBar(SnackBar(content: Text(text)));
      });
    } catch (_) {
      _ready = false;
    }
  }

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool('pushEnabled') ?? false;
  }

  /// Asks the phone's permission, then saves this phone's address.
  /// Returns false if alerts could not be turned on.
  static Future<bool> enable() async {
    if (!_ready) return false;
    final settings = await FirebaseMessaging.instance.requestPermission();
    final status = settings.authorizationStatus;
    final allowed = status == AuthorizationStatus.authorized ||
        status == AuthorizationStatus.provisional;
    if (!allowed) return false;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pushEnabled', true);
    await _register();
    return true;
  }

  static Future<void> disable() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('pushEnabled', false);
    await unregister();
  }

  /// Called after login: refreshes the saved address if alerts are on.
  static Future<void> registerIfEnabled() async {
    if (!_ready) return;
    if (!await isEnabled()) return;
    await _register();
  }

  static Future<void> _register() async {
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null) await _save(token);
      _refreshSub ??= FirebaseMessaging.instance.onTokenRefresh.listen(_save);
    } catch (_) {
      // Try again next time the app opens
    }
  }

  static Future<void> _save(String token) async {
    if (Supabase.instance.client.auth.currentUser == null) return;
    try {
      await Supabase.instance.client
          .rpc('register_device', params: {'p_token': token});
    } catch (_) {
      // Offline: the address is saved at the next login
    }
  }

  /// Removes this phone from the logged-in runner's alerts.
  static Future<void> unregister() async {
    if (!_ready) return;
    try {
      final token = await FirebaseMessaging.instance.getToken();
      if (token != null && Supabase.instance.client.auth.currentUser != null) {
        await Supabase.instance.client
            .rpc('unregister_device', params: {'p_token': token});
      }
    } catch (_) {
      // Ignore: the phone will simply stop getting alerts when it logs out
    }
  }
}
