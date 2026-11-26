import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:pair_mobile/api.dart';
import 'package:pair_mobile/app.dart';
import 'package:pair_mobile/models.dart';
import 'package:pair_mobile/profile_screens.dart';
import 'package:pair_mobile/social_screens.dart';

import 'api_test.dart' show MemoryStore;

void main() {
  testWidgets('registration verifies code before creating a session', (
    tester,
  ) async {
    final requests = <http.Request>[];
    var activationAttempts = 0;
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/register')) {
          return http.Response('{"message":"If available"}', 202);
        }
        if (request.url.path.endsWith('/activate')) {
          activationAttempts++;
          if (activationAttempts == 1) {
            return http.Response('{"error":"Invalid or expired code"}', 400);
          }
          return http.Response(
            '{"message":"Created"}',
            201,
            headers: {'set-cookie': 'session=abc; Path=/'},
          );
        }
        if (request.url.path.endsWith('/me')) {
          return http.Response(
            jsonEncode({
              'id': 1,
              'email': 'test@example.test',
              'verified': true,
              'profile': null,
              'preferences': null,
              'photo': 'missing',
              'answers': {},
              'ready': false,
              'matching_paused': false,
            }),
            200,
          );
        }
        return http.Response('{"error":"unexpected"}', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: PairApp(api: api)));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'test@example.test',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(jsonDecode(requests.first.body), {'email': 'test@example.test'});
    expect(api.hasSession, isFalse);
    expect(find.text('Complete registration'), findsOneWidget);
    await tester.enterText(find.byType(TextFormField).at(0), 'test-code');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'a secure password',
    );
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create account'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid or expired code'), findsOneWidget);
    expect(find.text('test-code'), findsOneWidget);
    expect(api.hasSession, isFalse);
    await tester.ensureVisible(find.text('Use a different email'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Use a different email'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).first,
      'other@example.test',
    );
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Continue'));
    await tester.pumpAndSettle();
    expect(find.text('test-code'), findsNothing);
    await tester.enterText(find.byType(TextFormField).at(0), 'test-code');
    await tester.enterText(
      find.byType(TextFormField).at(1),
      'a secure password',
    );
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(CheckboxListTile));
    await tester.ensureVisible(
      find.widgetWithText(FilledButton, 'Create account'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create account'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(
      jsonDecode(
        requests
            .lastWhere((request) => request.url.path.endsWith('/activate'))
            .body,
      ),
      {'code': 'test-code', 'password': 'a secure password', 'adult': true},
    );
  });

  testWidgets('sign in shows incomplete onboarding and can open preferences', (
    tester,
  ) async {
    final store = MemoryStore();
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: store,
      client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) {
          return http.Response(
            '{"message":"ok"}',
            200,
            headers: {'set-cookie': 'session=abc; Path=/'},
          );
        }
        if (request.url.path.endsWith('/me')) {
          return http.Response(
            jsonEncode({
              'id': 1,
              'email': 'test@example.test',
              'verified': false,
              'profile': null,
              'preferences': null,
              'photo': 'missing',
              'answers': {},
              'ready': false,
              'matching_paused': false,
            }),
            200,
          );
        }
        return http.Response('{"error":"unexpected"}', 404);
      }),
    );
    await tester.pumpWidget(MaterialApp(home: PairApp(api: api)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'test@example.test',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'password');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Compatibility questions (0/64)'), findsOneWidget);
    await tester.ensureVisible(find.text('Dating preferences'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Dating preferences'));
    await tester.pumpAndSettle();
    expect(
      find.text('Both people must meet each other’s preferences.'),
      findsOneWidget,
    );
    await tester.enterText(find.byType(TextFormField).first, '25');
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.text('25'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(OnboardingScreen), findsOneWidget);
  });

  testWidgets('login failure is visible without entering the app', (
    tester,
  ) async {
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient(
        (request) async =>
            http.Response('{"error":"Invalid credentials"}', 401),
      ),
    );
    await tester.pumpWidget(MaterialApp(home: PairApp(api: api)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Already have an account? Sign in'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextFormField).at(0),
      'test@example.test',
    );
    await tester.enterText(find.byType(TextFormField).at(1), 'bad');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid credentials'), findsOneWidget);
    expect(find.text('Complete your profile'), findsNothing);
  });

  testWidgets('a failed answer is not displayed as saved', (tester) async {
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path.endsWith('/questions')) {
          return http.Response(
            jsonEncode([
              for (var id = 1; id <= 64; id++)
                {
                  'id': id,
                  'category': 'Category ${(id - 1) ~/ 8 + 1}',
                  'text': 'Statement $id',
                },
            ]),
            200,
          );
        }
        return http.Response('{"error":"Answer could not be saved"}', 500);
      }),
    );
    final controller = AppController(api);
    controller.account = const Account(
      id: 1,
      email: 'test@example.test',
      verified: true,
      profile: null,
      preferences: null,
      photo: 'missing',
      answers: {},
      ready: false,
      matchingPaused: false,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: QuestionnaireScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Agree').last);
    await tester.pumpAndSettle();
    expect(find.text('Answer could not be saved'), findsOneWidget);
    expect(find.text('0 / 64 answered'), findsOneWidget);
    expect(find.text('Agree'), findsNothing);
    api.close();
    controller.dispose();
  });

  testWidgets('privacy pause is saved and displayed', (tester) async {
    var paused = false;
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/privacy') {
          paused = jsonDecode(request.body)['matching_paused'] as bool;
          return http.Response('{}', 200);
        }
        if (request.url.path == '/api/v1/me') {
          return http.Response(
            jsonEncode({
              'id': 1,
              'email': 'test@example.test',
              'verified': true,
              'profile': null,
              'preferences': null,
              'photo': 'missing',
              'answers': {},
              'ready': false,
              'matching_paused': paused,
            }),
            200,
          );
        }
        return http.Response('{"error":"unexpected"}', 404);
      }),
    );
    final controller = AppController(api);
    await controller.refresh();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: SettingsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(paused, isTrue);
    expect(controller.account!.matchingPaused, isTrue);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    api.close();
    controller.dispose();
  });

  testWidgets('private invitation can be accepted without a weekly match', (
    tester,
  ) async {
    var accepted = false;
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/matches') {
          return http.Response(
            jsonEncode({
              'cycle': null,
              'matches': [],
              'invitations': accepted
                  ? []
                  : [
                      {
                        'id': 2,
                        'name': 'Alex',
                        'age': 29,
                        'distance_label': 'About 25 km away',
                        'intention': 'serious',
                        'bio': 'A short biography',
                        'score': 85,
                        'breakdown': {'Values': 85},
                        'shared_interests': [],
                        'similarities': [],
                        'reaction': null,
                      },
                    ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/matches/2/reaction') {
          expect(jsonDecode(request.body), {'kind': 'like'});
          accepted = true;
          return http.Response('{}', 200);
        }
        return http.Response('{"error":"Photo unavailable"}', 404);
      }),
    );
    final controller = AppController(api);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: IntroductionsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private invitations'), findsOneWidget);
    expect(find.text('Alex, 29'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Like'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Like'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(find.text('Alex, 29'), findsNothing);
    api.close();
    controller.dispose();
  });

  testWidgets('blocking hides the old introduction while the list reloads', (
    tester,
  ) async {
    final pending = Completer<http.Response>();
    var matchRequests = 0;
    final api = PairApi(
      baseUrl: 'http://localhost:5000',
      allowDebugHttp: true,
      sessionStore: MemoryStore(),
      client: MockClient((request) async {
        if (request.url.path == '/api/v1/matches') {
          matchRequests++;
          if (matchRequests > 1) return pending.future;
          return http.Response(
            jsonEncode({
              'cycle': null,
              'invitations': [],
              'matches': [
                {
                  'id': 2,
                  'name': 'Alex',
                  'age': 29,
                  'distance_label': 'About 25 km away',
                  'intention': 'serious',
                  'bio': 'A short biography',
                  'score': 85,
                  'breakdown': {'Values': 85},
                  'shared_interests': [],
                  'similarities': [],
                  'reaction': null,
                },
              ],
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/safety/2') {
          return http.Response('{"message":"blocked"}', 200);
        }
        return http.Response('{"error":"Photo unavailable"}', 404);
      }),
    );
    final controller = AppController(api);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: IntroductionsScreen(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alex, 29'), findsOneWidget);
    await tester.ensureVisible(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Block'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Block'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Alex, 29'), findsNothing);
    pending.complete(
      http.Response('{"cycle":null,"matches":[],"invitations":[]}', 200),
    );
    await tester.pumpAndSettle();
    expect(find.text('No introductions yet'), findsOneWidget);
    api.close();
    controller.dispose();
  });
}
