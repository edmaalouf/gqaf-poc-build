import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'api.dart';
import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  const configured = String.fromEnvironment('PAIR_API_URL');
  final base = configured.isNotEmpty
      ? configured
      : (kDebugMode && defaultTargetPlatform == TargetPlatform.android
            ? 'http://10.0.2.2:5000'
            : 'http://127.0.0.1:5000');
  runApp(PairRoot(baseUrl: base));
}

class PairRoot extends StatelessWidget {
  const PairRoot({super.key, required this.baseUrl});
  final String baseUrl;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xff28614e),
      surface: const Color(0xfff7f8f3),
      primary: const Color(0xff174f3f),
    );
    return MaterialApp(
      title: 'Pair',
      debugShowCheckedModeBanner: false,
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      supportedLocales: const [Locale('en')],
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: scheme.surface,
        inputDecorationTheme: const InputDecorationTheme(
          border: OutlineInputBorder(),
          alignLabelWithHint: true,
        ),
        cardTheme: CardThemeData(
          color: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: Color(0xffdce6dd)),
          ),
        ),
      ),
      home: Builder(
        builder: (context) {
          try {
            return PairApp(
              api: PairApi(
                baseUrl: baseUrl,
                sessionStore: const SecureSessionStore(),
              ),
            );
          } on FormatException catch (error) {
            return Scaffold(
              appBar: AppBar(title: const Text('Configuration error')),
              body: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  '${error.message} Set PAIR_API_URL to your API origin.',
                ),
              ),
            );
          }
        },
      ),
    );
  }
}
