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
          ];
          return Scaffold(
            appBar: AppBar(
              title: Text.rich(
                const TextSpan(
                  children: [
                    TextSpan(text: 'pair'),
                    TextSpan(
                      text: '.',
                      style: TextStyle(color: Color(0xffc98462)),
                    ),
                  ],
                ),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                ),
              ),
              actions: [
                IconButton(
                  tooltip: 'Account',
                  onPressed: () => _showAccountMenu(context),
                  icon: const Icon(Icons.account_circle_outlined),
                ),
              ],
            ),
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
                  label: 'Questions',
                ),
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: 'Messages',
                ),
              ],
            ),
          );
        },
      );
    },
  );

  void _showAccountMenu(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.person_outline),
              title: const Text('Your profile'),
              onTap: () {
                Navigator.pop(sheetContext);
                openPage(
                  context,
                  ProfileOverview(controller: controller, standalone: true),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('Settings & safety'),
              onTap: () {
                Navigator.pop(sheetContext);
                openPage(
                  context,
                  SettingsScreen(controller: controller, standalone: true),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
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
    backgroundColor: const Color(0xff203b32),
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 18, 22, 28),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.join_inner_rounded,
                      color: Color(0xfff3b594),
                      size: 31,
                    ),
                    const SizedBox(width: 8),
                    Text.rich(
                      const TextSpan(
                        children: [
                          TextSpan(text: 'pair'),
                          TextSpan(
                            text: '.',
                            style: TextStyle(color: Color(0xfff3b594)),
                          ),
                        ],
                      ),
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -1.2,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 32),
                Text(
                  'A little less scrolling.\nA lot more meaning.',
                  style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                    color: const Color(0xfff8faf5),
                    fontWeight: FontWeight.w700,
                    height: 1.06,
                    letterSpacing: -1.4,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Thoughtful introductions, shaped by what matters to you.',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: const Color(0xffe1ebe4),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 22),
                Row(
                  children: [
                    _WelcomeFact(value: '64', label: 'thoughtful questions'),
                    const SizedBox(width: 12),
                    _WelcomeFact(
                      value: '3',
                      label: 'introductions a week, max',
                    ),
                  ],
                ),
                const SizedBox(height: 26),
                Container(
                  padding: const EdgeInsets.all(22),
                  decoration: BoxDecoration(
                    color: const Color(0xfffffefa),
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: const [
                      BoxShadow(
                        color: Color(0x330d2119),
                        blurRadius: 28,
                        offset: Offset(0, 12),
                      ),
                    ],
                  ),
                  child: Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          register
                              ? activation
                                    ? 'You’re almost in.'
                                    : 'Start with a hello.'
                              : 'Welcome back.',
                          style: Theme.of(context).textTheme.headlineSmall
                              ?.copyWith(
                                color: const Color(0xff202b26),
                                fontWeight: FontWeight.w700,
                                letterSpacing: -0.5,
                              ),
                        ),
                        const SizedBox(height: 5),
                        Text(
                          register
                              ? activation
                                    ? 'Verify your email to create your account.'
                                    : 'Make room for a more intentional kind of dating.'
                              : 'Your next meaningful introduction starts here.',
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(color: const Color(0xff52635a)),
                        ),
                        const SizedBox(height: 17),
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
                        const SizedBox(height: 14),
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
                          Material(
                            color: Colors.transparent,
                            child: CheckboxListTile(
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
                          ),
                        const SizedBox(height: 12),
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
                        Center(
                          child: TextButton(
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
                        ),
                        if (register && activation)
                          Center(
                            child: TextButton(
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
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const Text(
                  'For adults looking for real connection. Local prototype: use test data only.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Color(0xffdce7df),
                    fontSize: 12,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class _WelcomeFact extends StatelessWidget {
  const _WelcomeFact({required this.value, required this.label});
  final String value, label;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Container(
      constraints: const BoxConstraints(minHeight: 76),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xff2e4a3f),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xff597165)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Color(0xfff3b594),
              fontSize: 19,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(
              color: Color(0xffe1ebe4),
              fontSize: 11,
              height: 1.3,
            ),
          ),
        ],
      ),
    ),
  );
}
