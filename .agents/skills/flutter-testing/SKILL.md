---
name: flutter-testing
description: Flutter unit, widget, and integration testing guidance for reliable behavior-focused app tests.
---

# Testing — Flutter

You are an expert in testing for building cross-platform apps with Flutter.

## Core Philosophy

Flutter's testing framework is designed around three levels with clear purposes: unit tests verify Dart logic without the Flutter framework, widget tests verify individual widgets in isolation with a lightweight rendering engine, and integration tests verify the full app on a device. The testing pyramid applies directly: many unit tests (fast, cheap, reliable), moderate widget tests (fast enough, test visual behavior), few integration tests (slow, flaky, but cover real end-to-end flows). Inverting this pyramid -- many integration tests, few unit tests -- creates a test suite that is slow, expensive to maintain, and flaky in CI.

Widget tests are Flutter's unique strength. Unlike iOS or Android testing, where UI tests require a running emulator and take seconds per test, Flutter widget tests run on the JVM with a lightweight rendering engine that executes in milliseconds. You can `pumpWidget`, tap buttons, enter text, and verify displayed content at the speed of unit tests. This means behaviors that would require slow instrumented tests on other platforms -- form validation, error state rendering, list scrolling -- can be tested quickly and reliably in widget tests.

Mocking with Mocktail (or Mockito) should happen at the dependency boundary, not at the implementation level. Mock the `ProductRepository` to return controlled data, then test that the `ProductListScreen` renders the data correctly. Do not mock internal widgets, framework methods, or pure functions. Testing that a widget calls `setState` or that a specific internal method was invoked tests the implementation, not the behavior. When the implementation changes, those tests break even though the app still works correctly.

## Anti-Patterns

- **Using pump() when pumpAndSettle() is needed**: `pump()` renders exactly one frame. If a widget triggers an animation, a navigation transition, or an async operation, `pump()` will show the intermediate state, not the final result. Use `pumpAndSettle()` to wait until all frames and animations complete before making assertions.

- **Not wrapping widgets in MaterialApp during widget tests**: Most Flutter widgets depend on `MediaQuery`, `Theme`, `Navigator`, and `Directionality`, all of which are provided by `MaterialApp`. Testing a widget without this wrapper produces cryptic errors like "No MediaQuery widget ancestor found." Always wrap test widgets in `MaterialApp(home: Scaffold(body: ...))`.

- **Testing visual details instead of behavior**: Asserting that a specific `TextStyle` has `fontSize: 14` tests the design implementation, not the behavior. When the design changes, these tests break without any functional impact. Test behavior: does the error message appear? Does the button call the correct callback? Does the list show the right items?

- **Forgetting addTearDown(container.dispose) in Riverpod provider tests**: A `ProviderContainer` that is not disposed after the test leaks state into subsequent tests, causing flaky results that depend on test execution order. Always call `addTearDown(container.dispose)` immediately after creating the container.

- **Running golden tests across different platforms without pinning**: Golden tests compare pixel-by-pixel against reference images. Different platforms (macOS, Linux, Windows) render text and widgets with subtle differences, causing golden tests to fail on CI even though the widget is visually correct. Run golden tests on a consistent platform, typically in CI with a pinned OS image.

## Overview

Flutter provides a rich testing framework spanning unit tests (pure Dart logic), widget tests (single widgets in isolation), and integration tests (full app on a device or emulator). This skill covers all three layers along with mocking, golden tests, and CI-friendly patterns.

## Core Concepts

### Unit Testing

Unit tests verify pure Dart logic — models, repositories, utility functions — with no Flutter framework dependency.

```dart
import 'package:test/test.dart';

void main() {
  group('Cart', () {
    late Cart cart;

    setUp(() {
      cart = Cart();
    });

    test('starts empty', () {
      expect(cart.items, isEmpty);
      expect(cart.total, equals(0));
    });

    test('adds items and computes total', () {
      cart.add(CartItem(id: '1', name: 'Widget', price: 9.99, quantity: 2));
      cart.add(CartItem(id: '2', name: 'Gadget', price: 24.99, quantity: 1));

      expect(cart.items, hasLength(2));
      expect(cart.total, closeTo(44.97, 0.01));
    });

    test('removes item by id', () {
      cart.add(CartItem(id: '1', name: 'Widget', price: 9.99, quantity: 1));
      cart.removeById('1');

      expect(cart.items, isEmpty);
    });
  });
}
```

### Widget Testing

Widget tests render a single widget with `pumpWidget` and interact with it through finders and gestures.

```dart
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('LoginForm shows error on empty submit', (tester) async {
    var submitted = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginForm(
            onSubmit: (email, password) => submitted = true,
          ),
        ),
      ),
    );

    // Tap submit without entering credentials
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(find.text('Email is required'), findsOneWidget);
    expect(submitted, isFalse);
  });

  testWidgets('LoginForm calls onSubmit with valid input', (tester) async {
    String? submittedEmail;
    String? submittedPassword;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LoginForm(
            onSubmit: (email, password) {
              submittedEmail = email;
              submittedPassword = password;
            },
          ),
        ),
      ),
    );

    await tester.enterText(find.byKey(const Key('email_field')), 'user@example.com');
    await tester.enterText(find.byKey(const Key('password_field')), 'secret123');
    await tester.tap(find.byType(ElevatedButton));
    await tester.pumpAndSettle();

    expect(submittedEmail, equals('user@example.com'));
    expect(submittedPassword, equals('secret123'));
  });
}
```

### Mocking with Mocktail

```dart
import 'package:mocktail/mocktail.dart';

class MockProductRepository extends Mock implements ProductRepository {}

void main() {
  late MockProductRepository mockRepo;

  setUp(() {
    mockRepo = MockProductRepository();
  });

  testWidgets('ProductList shows products from repository', (tester) async {
    final products = [
      Product(id: '1', name: 'Laptop', price: 999.0),
      Product(id: '2', name: 'Phone', price: 699.0),
    ];

    when(() => mockRepo.getProducts()).thenAnswer((_) async => products);

    await tester.pumpWidget(
      MaterialApp(
        home: ProductList(repository: mockRepo),
      ),
    );

    // Show loading indicator first
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pumpAndSettle();

    expect(find.text('Laptop'), findsOneWidget);
    expect(find.text('Phone'), findsOneWidget);
    verify(() => mockRepo.getProducts()).called(1);
  });

  testWidgets('ProductList shows error state', (tester) async {
    when(() => mockRepo.getProducts()).thenThrow(Exception('Network error'));

    await tester.pumpWidget(
      MaterialApp(
        home: ProductList(repository: mockRepo),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsOneWidget); // retry button
  });
}
```

## Implementation Patterns

### Testing Bloc

```dart
import 'package:bloc_test/bloc_test.dart';

void main() {
  late MockAuthRepository mockAuthRepo;

  setUp(() {
    mockAuthRepo = MockAuthRepository();
  });

  group('AuthBloc', () {
    blocTest<AuthBloc, AuthState>(
      'emits [AuthLoading, AuthAuthenticated] on successful login',
      build: () {
        when(() => mockAuthRepo.login('user@test.com', 'pass'))
            .thenAnswer((_) async => User(id: '1', email: 'user@test.com'));
        return AuthBloc(mockAuthRepo);
      },
      act: (bloc) => bloc.add(AuthLoginRequested('user@test.com', 'pass')),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthAuthenticated>()
            .having((s) => s.user.email, 'email', 'user@test.com'),
      ],
    );

    blocTest<AuthBloc, AuthState>(
      'emits [AuthLoading, AuthFailure] on failed login',
      build: () {
        when(() => mockAuthRepo.login(any(), any()))
            .thenThrow(Exception('Invalid credentials'));
        return AuthBloc(mockAuthRepo);
      },
      act: (bloc) => bloc.add(AuthLoginRequested('bad@test.com', 'wrong')),
      expect: () => [
        isA<AuthLoading>(),
        isA<AuthFailure>(),
      ],
    );
  });
}
```

### Testing Riverpod Providers

```dart
void main() {
  test('cartNotifierProvider adds and removes items', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(cartNotifierProvider.notifier);

    expect(container.read(cartNotifierProvider), isEmpty);

    notifier.addItem(CartItem(id: '1', name: 'Book', price: 15.0, quantity: 1));
    expect(container.read(cartNotifierProvider), hasLength(1));

    notifier.removeItem('1');
    expect(container.read(cartNotifierProvider), isEmpty);
  });

  test('cartNotifierProvider can use overridden dependencies', () async {
    final mockRepo = MockCartRepository();
    when(() => mockRepo.loadCart()).thenAnswer((_) async => [
      CartItem(id: '1', name: 'Saved Item', price: 10.0, quantity: 1),
    ]);

    final container = ProviderContainer(
      overrides: [
        cartRepositoryProvider.overrideWithValue(mockRepo),
      ],
    );
    addTearDown(container.dispose);

    await container.read(cartNotifierProvider.future);
    expect(container.read(cartNotifierProvider).value, hasLength(1));
  });
}
```

### Golden Tests

Golden tests compare rendered widgets against reference images to catch visual regressions.

```dart
testWidgets('ProductCard matches golden', (tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ProductCard(
            product: Product(id: '1', name: 'Test', price: 29.99),
          ),
        ),
      ),
    ),
  );

  await expectLater(
    find.byType(ProductCard),
    matchesGoldenFile('goldens/product_card.png'),
  );
});

// Update goldens: flutter test --update-goldens
```

### Integration Testing

```dart
// integration_test/app_test.dart
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('full login flow', (tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pumpAndSettle();

    // Login screen
    await tester.enterText(find.byKey(const Key('email_field')), 'user@test.com');
    await tester.enterText(find.byKey(const Key('password_field')), 'password');
    await tester.tap(find.text('Sign In'));
    await tester.pumpAndSettle();

    // Verify we reached the home screen
    expect(find.text('Welcome'), findsOneWidget);
  });
}
```

## Best Practices

- **Follow the testing pyramid**: many unit tests, moderate widget tests, few integration tests. Unit tests are fast and cheap; integration tests are slow and flaky.
- **Use `pumpAndSettle()` after actions** that trigger animations or async work. It waits until all frames are rendered and timers complete.
- **Give testable widgets `Key` parameters** so tests can find specific fields without relying on fragile text matchers.
- **Override providers/dependencies in tests** rather than mocking at the HTTP level. This makes tests more focused and less brittle.
- **Run golden tests only on CI** with a consistent platform to avoid cross-platform rendering differences.

## Common Pitfalls

- **Using `pump()` when `pumpAndSettle()` is needed**: `pump()` only renders one frame. If the widget triggers navigation or animations, the test will not see the final state.
- **Not wrapping widgets in `MaterialApp`**: Many widgets depend on `MediaQuery`, `Theme`, or `Navigator` from `MaterialApp`. Missing this causes cryptic errors.
- **Testing implementation details**: Testing that a specific `setState` call happened is brittle. Test the visible output instead.
- **Flaky integration tests from animation timing**: Use `tester.pumpAndSettle(const Duration(seconds: 5))` with a generous timeout for slow CI environments.
- **Forgetting `addTearDown(container.dispose)`**: Leaking `ProviderContainer` instances causes state to bleed between tests.
