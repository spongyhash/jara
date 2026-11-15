import 'dart:convert';
import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'models.dart';
import 'push.dart';
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
  bool pushOn = false;
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
    final push = prefs.getBool('pushEnabled') ?? false;
    if (!mounted) return;
    setState(() {
      hideEnds = value;
      pushOn = push;
    });
  }

  Future<void> setPush(bool value) async {
    if (!value) {
      setState(() => pushOn = false);
      await Push.disable();
      return;
    }
    final yes = await askYesNo(
      context,
      title: 'Turn on territory alerts?',
      message: 'Jara will send you a notification when someone takes or '
          'weakens one of your cells, even when the app is closed. You can '
          'turn this off any time.',
      yes: 'Turn on',
      no: 'Not now',
    );
    if (!yes || !mounted) return;
    final ok = await Push.enable();
    if (!mounted) return;
    setState(() => pushOn = ok);
    if (!ok) {
      toast('Alerts could not be turned on. Check that notifications are '
          'allowed for Jara in your phone settings.');
    }
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

  Future<void> exportData() async {
    setState(() {
      busy = true;
      busyText = 'Preparing your data...';
    });
    try {
      final data = await client.rpc('export_my_data');
      final text = const JsonEncoder.withIndent('  ').convert(data);
      await SharePlus.instance.share(
        ShareParams(
          files: [
            XFile.fromData(
              Uint8List.fromList(utf8.encode(text)),
              mimeType: 'application/json',
            ),
          ],
          fileNameOverrides: ['jara_my_data.json'],
        ),
      );
    } catch (_) {
      if (mounted) toast('Could not prepare your data. Check your internet.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  /// A second, harder confirmation: the runner must type DELETE.
  Future<bool> confirmTyped() async {
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Type DELETE to confirm'),
          content: TextField(
            controller: ctrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setLocal(() {}),
            decoration: const InputDecoration(hintText: 'DELETE'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: ctrl.text.trim() == 'DELETE'
                  ? () => Navigator.pop(ctx, true)
                  : null,
              child: const Text('Delete forever'),
            ),
          ],
        ),
      ),
    );
    return ok ?? false;
  }

  Future<void> deleteAccount() async {
    final first = await askYesNo(
      context,
      title: 'Delete your account?',
      message: 'This permanently erases your profile, all your runs and '
          'routes, and your territory. Cells you own become free for others. '
          'It cannot be undone.',
      yes: 'Continue',
      no: 'Cancel',
    );
    if (!first || !mounted) return;
    final typed = await confirmTyped();
    if (!typed || !mounted) return;

    setState(() {
      busy = true;
      busyText = 'Deleting your account...';
    });
    try {
      await client.rpc('delete_my_account');
    } catch (_) {
      if (mounted) {
        setState(() => busy = false);
        toast('Could not delete your account. Check your internet and try again.');
      }
      return;
    }

    await SyncService.clearLocalData();
    try {
      await client.auth.signOut(scope: SignOutScope.local);
    } catch (_) {
      // The account is already gone; the app returns to the login screen
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

    await Push.unregister();
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
          SwitchListTile(
            secondary: const Icon(Icons.notifications_outlined),
            title: const Text('Territory alerts'),
            subtitle: const Text(
                'A notification when someone takes or weakens your cells'),
            value: pushOn,
            onChanged: setPush,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Download my data'),
            subtitle: const Text('A copy of your profile, runs and territory'),
            onTap: exportData,
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout, color: Colors.red),
            title: const Text('Log out', style: TextStyle(color: Colors.red)),
            onTap: logOut,
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever, color: Colors.red),
            title: const Text('Delete my account',
                style: TextStyle(color: Colors.red)),
            subtitle: const Text('Erases everything permanently'),
            onTap: deleteAccount,
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
