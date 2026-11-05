import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class AuthPage extends StatefulWidget {
  const AuthPage({super.key});

  @override
  State<AuthPage> createState() => _AuthPageState();
}

class _AuthPageState extends State<AuthPage> {
  final TextEditingController nameCtrl = TextEditingController();
  final TextEditingController emailCtrl = TextEditingController();
  final TextEditingController passCtrl = TextEditingController();

  bool signUp = false;
  bool busy = false;
  bool hidePass = true;
  String? error;
  String? notice;

  @override
  void dispose() {
    nameCtrl.dispose();
    emailCtrl.dispose();
    passCtrl.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    final email = emailCtrl.text.trim();
    final pass = passCtrl.text;
    var name = nameCtrl.text.trim();
    if (name.length > 30) name = name.substring(0, 30);

    if (signUp && name.isEmpty) {
      setState(() => error = 'Tell us what to call you');
      return;
    }
    if (email.isEmpty || !email.contains('@')) {
      setState(() => error = 'Enter a valid email address');
      return;
    }
    if (pass.length < 6) {
      setState(() => error = 'Password must be at least 6 characters');
      return;
    }

    setState(() {
      busy = true;
      error = null;
      notice = null;
    });

    try {
      final auth = Supabase.instance.client.auth;
      if (signUp) {
        final res = await auth.signUp(
          email: email,
          password: pass,
          data: {'display_name': name},
        );
        // No session means the project still asks for email confirmation
        if (res.session == null && mounted) {
          setState(() {
            notice = 'Check your email to confirm your account, then log in.';
            signUp = false;
          });
        }
      } else {
        await auth.signInWithPassword(email: email, password: pass);
      }
      // On success the app switches screens by itself (see AuthGate)
    } on AuthException catch (e) {
      if (mounted) setState(() => error = e.message);
    } catch (e) {
      if (mounted) {
        setState(() =>
            error = 'Could not connect. Check your internet and try again.');
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              children: [
                Icon(Icons.directions_run,
                    size: 72, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                const Text('Jara',
                    style:
                        TextStyle(fontSize: 36, fontWeight: FontWeight.w800)),
                const Text('Go the extra mile'),
                const SizedBox(height: 32),
                if (signUp) ...[
                  TextField(
                    controller: nameCtrl,
                    maxLength: 30,
                    textCapitalization: TextCapitalization.words,
                    decoration: const InputDecoration(
                      labelText: 'What should we call you?',
                      prefixIcon: Icon(Icons.person_outline),
                      border: OutlineInputBorder(),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                TextField(
                  controller: emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.mail_outline),
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtrl,
                  obscureText: hidePass,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outline),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(
                          hidePass ? Icons.visibility : Icons.visibility_off),
                      onPressed: () => setState(() => hidePass = !hidePass),
                    ),
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(error!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.red)),
                  ),
                if (notice != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(notice!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.green)),
                  ),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 54,
                  child: FilledButton(
                    onPressed: busy ? null : submit,
                    child: Text(
                      busy
                          ? 'Please wait...'
                          : (signUp ? 'Create account' : 'Log in'),
                      style: const TextStyle(fontSize: 18),
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => setState(() {
                            signUp = !signUp;
                            error = null;
                            notice = null;
                          }),
                  child: Text(signUp
                      ? 'I already have an account'
                      : 'New here? Create an account'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
