import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';
import 'sync.dart';
import 'widgets.dart';

/// Bumped when the display name changes, so greetings refresh.
final ValueNotifier<int> profileChanged = ValueNotifier<int>(0);

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  bool hideEnds = true;
  bool busy = false;
  String busyText = '';

  SupabaseClient get client => Supabase.instance.client;

  @override
  void initState() {
    super.initState();
    loadSettings();
  }

  Future<void> loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getBool('hideRouteEnds') ?? true;
    if (!mounted) return;
    setState(() => hideEnds = value);
  }

  void toast(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> setHideEnds(bool value) async {
    setState(() => hideEnds = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('hideRouteEnds', value);
    try {
      final id = client.auth.currentUser?.id;
      if (id != null) {
        await client
            .from('profiles')
            .update({'hide_route_ends': value}).eq('id', id);
      }
    } catch (_) {
      // The setting is saved on the phone, which is what the app uses
    }
  }

  Future<void> editName() async {
    final ctrl = TextEditingController(text: userName());
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          maxLength: 30,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(hintText: 'What should we call you?'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newName == null || newName.isEmpty) return;

    setState(() {
      busy = true;
      busyText = 'Saving...';
    });
    try {
      await client.auth.updateUser(
        UserAttributes(data: {'display_name': newName}),
      );
      final id = client.auth.currentUser?.id;
      if (id != null) {
        await client
            .from('profiles')
            .update({'display_name': newName}).eq('id', id);
      }
      profileChanged.value++;
      if (mounted) toast('Name updated');
    } catch (_) {
      if (mounted) toast('Could not update your name. Check your internet.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> logOut() async {
    final yes = await askYesNo(
      context,
      title: 'Log out?',
      message: 'We will back up your runs to the cloud first, then clear this '
          'phone so the next person starts fresh. Log back in any time to '
          'get your runs back.',
      yes: 'Yes, log out',
      no: 'Cancel',
    );
    if (!yes || !mounted) return;

    setState(() {
      busy = true;
      busyText = 'Backing up your runs...';
    });

    final ok = await SyncService.syncNow();
    if (!mounted) return;

    if (!ok) {
      final force = await askYesNo(
        context,
        title: 'Could not back up',
        message: 'Some runs may not be in the cloud yet. If you log out now, '
            'they will be lost from this phone. Log out anyway?',
        yes: 'Log out anyway',
        no: 'Stay logged in',
      );
      if (!force || !mounted) {
        if (mounted) setState(() => busy = false);
        return;
      }
    }

    await SyncService.clearLocalData();
    await client.auth.signOut();
    // The app returns to the login screen by itself
  }

  @override
  Widget build(BuildContext context) {
    final name = userName();
    final email = client.auth.currentUser?.email ?? '';

    Widget body;
    if (busy) {
      body = Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            Text(busyText),
          ],
        ),
      );
    } else {
      body = ListView(
        children: [
          const SizedBox(height: 24),
          Center(
            child: CircleAvatar(
              radius: 44,
              backgroundColor: Theme.of(context).colorScheme.primary,
              child: Text(
                name.isEmpty ? '?' : name[0].toUpperCase(),
                style: const TextStyle(
                    fontSize: 40,
                    color: Colors.white,
                    fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Center(
            child: Text(name,
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
          ),
          Center(child: Text(email)),
          const SizedBox(height: 16),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.person_outline),
            title: const Text('Display name'),
            subtitle: Text(name),
            trailing: const Icon(Icons.edit),
            onTap: editName,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off_outlined),
            title: const Text('Hide start and end of my routes'),
            subtitle: const Text(
                'Hides the first and last 150 m when you share a run, so '
                'people cannot see where you live'),
            value: hideEnds,
            onChanged: setHideEnds,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Log out', style: TextStyle(color: Colors.red)),
            onTap: logOut,
          ),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: body,
    );
  }
}
