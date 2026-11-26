import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'api.dart';
import 'models.dart';
import 'profile_screens.dart';
import 'social_screens.dart';

class AppController extends ChangeNotifier {
  AppController(this.api);
  final PairApi api;
  Account? account;

  Future<void> initialize() async {
    await api.restore();
    if (api.hasSession) await refresh();
  }

  Future<void> refresh() async {
    account = await api.me();
    notifyListeners();
  }

  void signedOut() {
    account = null;
    notifyListeners();
  }
}

String errorMessage(Object error) {
  if (error is ApiException) return error.message;
  if (error is FormatException) {
    return 'Invalid response or configuration: ${error.message}';
  }
  if (error is PlatformException) {
    return 'Device service failed: ${error.message ?? error.code}';
  }
  return 'Something went wrong: $error';
}

Future<bool> runAction(
  BuildContext context,
  Future<void> Function() action, {
  String? success,
}) async {
  try {
    await action();
    if (context.mounted && success != null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(success)));
    }
    return true;
  } on Exception catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorMessage(error)),
          duration: const Duration(seconds: 8),
        ),
      );
    }
    return false;
  }
}

Future<void> openPage(BuildContext context, Widget page) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));

class PairApp extends StatefulWidget {
  const PairApp({super.key, required this.api});
  final PairApi api;

  @override
  State<PairApp> createState() => _PairAppState();
}

class _PairAppState extends State<PairApp> {
  late final AppController controller;
  late Future<void> initial;
  int tab = 0;

  @override
  void initState() {
    super.initState();
    controller = AppController(widget.api);
    widget.api.onUnauthorized = () {
      if (controller.account != null) {
        controller.signedOut();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
        });
      }
    };
    initial = controller.initialize();
  }

  @override
  void dispose() {
    widget.api.onUnauthorized = null;
    widget.api.close();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<void>(
    future: initial,
    builder: (context, snapshot) {
      if (snapshot.connectionState != ConnectionState.done) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      if (snapshot.hasError &&
          !(snapshot.error is ApiException &&
              (snapshot.error as ApiException).status == 401)) {
        return Scaffold(
          appBar: AppBar(title: const Text('Unable to start')),
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(errorMessage(snapshot.error!)),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () => setState(() {
                      initial = controller.initialize();
                    }),
                    child: const Text('Try again'),
                  ),
                ],
              ),
            ),
          ),
        );
      }
      return ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final account = controller.account;
          if (account == null) {
            tab = 0;
            return AuthScreen(controller: controller);
          }
          final pages = <Widget>[
            account.ready
                ? IntroductionsScreen(controller: controller)
                : OnboardingScreen(controller: controller),
            QuestionnaireScreen(controller: controller),
            ConversationsScreen(controller: controller),
            ProfileOverview(controller: controller),
            SettingsScreen(controller: controller),
          ];
          return Scaffold(
            body: SafeArea(child: pages[tab]),
            bottomNavigationBar: NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: (value) => setState(() => tab = value),
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.people_outline),
                  selectedIcon: Icon(Icons.people),
                  label: 'Matches',
                ),
                NavigationDestination(
                  icon: Icon(Icons.list_alt),
                  label: 'Answers',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Messages',
                ),
                NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'Profile',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: 'Settings',
                ),
              ],
            ),
          );
        },
      );
    },
  );
}

class PageBody extends StatelessWidget {
  const PageBody({
    super.key,
    required this.title,
    required this.subtitle,
    required this.children,
  });
  final String title, subtitle;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ListView(
    padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
    children: [
      Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
      ),
      const SizedBox(height: 8),
      Text(subtitle, style: Theme.of(context).textTheme.bodyLarge),
      const SizedBox(height: 24),
      ...children,
    ],
  );
}

class Panel extends StatelessWidget {
  const Panel({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 16),
    child: Padding(padding: const EdgeInsets.all(20), child: child),
  );
}

class AuthScreen extends StatefulWidget {
  const AuthScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  final form = GlobalKey<FormState>();
  final email = TextEditingController();
  final password = TextEditingController();
  final code = TextEditingController();
  bool register = true, activation = false, adult = false, busy = false;
  @override
  void dispose() {
    email.dispose();
    password.dispose();
    code.dispose();
    super.dispose();
  }

  Future<void> submit() async {
    if (!form.currentState!.validate()) return;
    if (register && activation && !adult) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Confirm that you are 18 or older.')),
      );
      return;
    }
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() => busy = true);
    await runAction(context, () async {
      if (register && !activation) {
        await widget.controller.api.request(
          'POST',
          '/api/v1/auth/register',
          body: {'email': email.text.trim()},
        );
        if (mounted) setState(() => activation = true);
        return;
      }
      await widget.controller.api.request(
        'POST',
        '/api/v1/auth/${register ? 'activate' : 'login'}',
        body: {
          if (!register) 'email': email.text.trim(),
          if (register) 'code': code.text.trim(),
          'password': password.text,
          if (register) 'adult': adult,
        },
      );
      if (!widget.controller.api.hasSession) {
        throw const ApiException('The server did not create a session.');
      }
      await widget.controller.refresh();
    });
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: PageBody(
            title: 'Dating without the endless scroll.',
            subtitle:
                'Up to three introductions each week, based on mutual preferences and compatibility.',
            children: [
              Panel(
                child: Form(
                  key: form,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        register
                            ? activation
                                  ? 'Complete registration'
                                  : 'Create your account'
                            : 'Sign in',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 20),
                      if (register && activation) ...[
                        const Text(
                          'If registration is available, check your email for a code. Otherwise, sign in.',
                        ),
                        const SizedBox(height: 16),
                        TextFormField(
                          controller: code,
                          decoration: const InputDecoration(
                            labelText: 'Registration code',
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter your registration code.'
                              : null,
                        ),
                      ] else
                        TextFormField(
                          controller: email,
                          keyboardType: TextInputType.emailAddress,
                          autofillHints: const [AutofillHints.email],
                          decoration: const InputDecoration(
                            labelText: 'Email address',
                          ),
                          validator: (v) => (v == null || v.trim().isEmpty)
                              ? 'Enter your email.'
                              : null,
                        ),
                      const SizedBox(height: 16),
                      if (!register || activation)
                        TextFormField(
                          controller: password,
                          obscureText: true,
                          autofillHints: [
                            register
                                ? AutofillHints.newPassword
                                : AutofillHints.password,
                          ],
                          decoration: InputDecoration(
                            labelText: 'Password',
                            helperText: register
                                ? 'At least 12 characters'
                                : null,
                          ),
                          validator: (v) =>
                              (v == null || v.length < (register ? 12 : 1))
                              ? 'Enter a valid password.'
                              : null,
                        ),
                      if (register && activation)
                        CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text(
                            'I confirm I am 18 or older and will treat others with respect.',
                          ),
                          value: adult,
                          onChanged: busy
                              ? null
                              : (value) =>
                                    setState(() => adult = value ?? false),
                        ),
                      const SizedBox(height: 16),
                      FilledButton(
                        onPressed: busy ? null : submit,
                        child: Text(
                          busy
                              ? 'Please wait…'
                              : register
                              ? activation
                                    ? 'Create account'
                                    : 'Continue'
                              : 'Sign in',
                        ),
                      ),
                      TextButton(
                        onPressed: busy
                            ? null
                            : () => setState(() {
                                register = !register;
                                activation = false;
                                code.clear();
                                password.clear();
                                adult = false;
                              }),
                        child: Text(
                          register
                              ? 'Already have an account? Sign in'
                              : 'New here? Create an account',
                        ),
                      ),
                      if (register && activation)
                        TextButton(
                          onPressed: busy
                              ? null
                              : () => setState(() {
                                  activation = false;
                                  code.clear();
                                  password.clear();
                                  adult = false;
                                }),
                          child: const Text('Use a different email'),
                        ),
                    ],
                  ),
                ),
              ),
              const Text(
                'Local prototype: do not use real personal data.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
