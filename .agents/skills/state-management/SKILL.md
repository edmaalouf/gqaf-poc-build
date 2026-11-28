---
name: state-management
description: Flutter state-management guidance for choosing local or shared state and structuring predictable, testable state transitions.
---

# State Management — Flutter

You are an expert in state management for building cross-platform apps with Flutter.

## Core Philosophy

State management in Flutter solves one core problem: how does a widget get the data it needs, and how does it know when that data changes? The simplest answer is `setState`, which works for local, widget-scoped state. But when multiple widgets need the same data, or when state must survive navigation, or when business logic becomes complex enough to test independently, you need a state management solution that separates state ownership from state consumption. Riverpod and Bloc are the two dominant approaches, and choosing one per project is more important than choosing the "right" one -- consistency matters more than theoretical superiority.

Riverpod's mental model is providers: globally declared, lazily initialized, automatically disposed, and composable. A provider declares what data it provides and what other providers it depends on. The framework handles the lifecycle, caching, and invalidation. This is a functional, declarative approach where state relationships are expressed as a dependency graph. Bloc's mental model is event-driven: events go in, state comes out, and the Bloc is a processor that transforms events into state transitions. This is an imperative approach where state changes are explicit and traceable.

Immutability is the common thread across both approaches. State classes should use `copyWith` or sealed classes to produce new instances rather than mutating fields in place. Mutable state that is modified without notification causes the UI to show stale data, and shared mutable references cause bugs where one widget's modification unexpectedly affects another widget's display. Immutable state transitions are predictable, testable, and free of aliasing bugs.

## Anti-Patterns

- **Overusing setState for app-wide concerns**: Managing authentication state, theme preferences, or user profiles with `setState` in a root widget and passing them down through constructor parameters creates deep prop drilling and makes state management invisible to the rest of the codebase. Use a proper state management solution for anything shared across multiple screens.

- **Using ref.watch inside callbacks instead of ref.read**: In Riverpod, `ref.watch` is for inside `build` methods -- it subscribes the widget to changes. Using `ref.watch` inside an `onPressed` callback does nothing useful and may cause unexpected behavior. Use `ref.read` for one-shot actions triggered by user interaction.

- **Not using sealed classes for Bloc events and states**: Without sealed classes, the Dart compiler cannot warn about unhandled cases in `switch` or `when` expressions. This means a new event or state added later will silently fall through without being handled, producing bugs that are caught only at runtime.

- **Storing derived data in state instead of computing it**: Keeping a `filteredList` alongside the source `list` and `filter` in state creates synchronization problems -- the filtered list can get out of sync with the source if an update forgets to recompute it. Compute derived values on-the-fly from the source state, using `select` or `BlocSelector` to avoid unnecessary rebuilds.

- **Not disposing Bloc-to-Bloc stream subscriptions**: When one Bloc subscribes to another Bloc's stream, the subscription must be cancelled in the `close()` method. A leaked subscription keeps the source Bloc alive, prevents garbage collection, and can cause state updates to arrive at a disposed Bloc.

## Overview

State management is the backbone of any non-trivial Flutter app. This skill covers two dominant approaches — Riverpod (declarative, provider-based) and Bloc (event-driven, stream-based) — along with guidance on when to use each and how to structure state for testability and scalability.

## Core Concepts

### Riverpod Fundamentals

Riverpod providers are globally declared, lazily initialized, and automatically disposed when no longer listened to.

```dart
// A simple async provider that fetches a user profile
@riverpod
Future<UserProfile> userProfile(Ref ref) async {
  final repo = ref.watch(userRepositoryProvider);
  return repo.fetchProfile();
}

// A notifier for mutable state
@riverpod
class CartNotifier extends _$CartNotifier {
  @override
  List<CartItem> build() => [];

  void addItem(CartItem item) {
    state = [...state, item];
  }

  void removeItem(String itemId) {
    state = state.where((i) => i.id != itemId).toList();
  }

  double get total => state.fold(0, (sum, i) => sum + i.price * i.quantity);
}
```

### Consuming Providers in Widgets

```dart
class CartScreen extends ConsumerWidget {
  const CartScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cart = ref.watch(cartNotifierProvider);
    final totalAsync = ref.watch(cartTotalProvider);

    return Scaffold(
      appBar: AppBar(title: Text('Cart (${cart.length})')),
      body: ListView.builder(
        itemCount: cart.length,
        itemBuilder: (context, index) => CartItemTile(item: cart[index]),
      ),
      bottomNavigationBar: totalAsync.when(
        data: (total) => CheckoutBar(total: total),
        loading: () => const LinearProgressIndicator(),
        error: (e, _) => ErrorBar(message: e.toString()),
      ),
    );
  }
}
```

### Bloc Fundamentals

Bloc separates events (inputs) from states (outputs) via a stream-based processor.

```dart
// Events
sealed class AuthEvent {}
class AuthLoginRequested extends AuthEvent {
  AuthLoginRequested(this.email, this.password);
  final String email;
  final String password;
}
class AuthLogoutRequested extends AuthEvent {}

// States
sealed class AuthState {}
class AuthInitial extends AuthState {}
class AuthLoading extends AuthState {}
class AuthAuthenticated extends AuthState {
  AuthAuthenticated(this.user);
  final User user;
}
class AuthFailure extends AuthState {
  AuthFailure(this.message);
  final String message;
}

// Bloc
class AuthBloc extends Bloc<AuthEvent, AuthState> {
  AuthBloc(this._authRepo) : super(AuthInitial()) {
    on<AuthLoginRequested>(_onLogin);
    on<AuthLogoutRequested>(_onLogout);
  }

  final AuthRepository _authRepo;

  Future<void> _onLogin(
    AuthLoginRequested event,
    Emitter<AuthState> emit,
  ) async {
    emit(AuthLoading());
    try {
      final user = await _authRepo.login(event.email, event.password);
      emit(AuthAuthenticated(user));
    } catch (e) {
      emit(AuthFailure(e.toString()));
    }
  }

  Future<void> _onLogout(
    AuthLogoutRequested event,
    Emitter<AuthState> emit,
  ) async {
    await _authRepo.logout();
    emit(AuthInitial());
  }
}
```

### Using Bloc in Widgets

```dart
class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<AuthBloc, AuthState>(
      listenWhen: (prev, curr) => curr is AuthAuthenticated || curr is AuthFailure,
      listener: (context, state) {
        if (state is AuthAuthenticated) {
          context.go('/home');
        } else if (state is AuthFailure) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text(state.message)));
        }
      },
      builder: (context, state) {
        if (state is AuthLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        return LoginForm(
          onSubmit: (email, password) {
            context.read<AuthBloc>().add(AuthLoginRequested(email, password));
          },
        );
      },
    );
  }
}
```

## Implementation Patterns

### Combining Riverpod Providers

```dart
@riverpod
Future<DashboardData> dashboard(Ref ref) async {
  // These run concurrently
  final results = await Future.wait([
    ref.watch(userProfileProvider.future),
    ref.watch(recentOrdersProvider.future),
    ref.watch(notificationsProvider.future),
  ]);

  return DashboardData(
    profile: results[0] as UserProfile,
    orders: results[1] as List<Order>,
    notifications: results[2] as List<AppNotification>,
  );
}
```

### Bloc-to-Bloc Communication

```dart
class OrderBloc extends Bloc<OrderEvent, OrderState> {
  OrderBloc({required AuthBloc authBloc, required OrderRepository repo})
      : _repo = repo,
        super(OrderInitial()) {
    // React to auth state changes
    _authSub = authBloc.stream.listen((authState) {
      if (authState is AuthAuthenticated) {
        add(OrderLoadRequested(authState.user.id));
      }
    });
    on<OrderLoadRequested>(_onLoad);
  }

  final OrderRepository _repo;
  late final StreamSubscription<AuthState> _authSub;

  @override
  Future<void> close() {
    _authSub.cancel();
    return super.close();
  }
}
```

## Best Practices

- **Choose one primary approach per project.** Mixing Riverpod and Bloc in the same app adds cognitive overhead. Pick one and stick with it.
- **Keep state classes immutable.** Use `copyWith` or sealed classes rather than mutating fields.
- **Separate UI state from domain state.** A form's validation errors are UI state; the user's profile is domain state.
- **Test state logic independently of widgets.** Both Riverpod and Bloc make it easy to unit-test state transitions without building widgets.
- **Use `select` / `BlocSelector` to minimize rebuilds.** Only listen to the slice of state the widget actually uses.

## Common Pitfalls

- **Overusing `setState`**: Reaching for local `setState` for app-wide concerns (auth, theme, locale) leads to prop drilling and spaghetti state.
- **Bloc event classes without sealed types**: Without sealed classes, the compiler cannot warn about unhandled events or states.
- **Riverpod: watching a provider in `onPressed`**: Use `ref.read` for one-shot actions inside callbacks; `ref.watch` is only for inside `build`.
- **Not disposing subscriptions**: Bloc-to-Bloc subscriptions must be cancelled in `close()` to prevent memory leaks.
- **Storing derived data in state**: Compute derived values (totals, filtered lists) from the source state rather than duplicating them.
