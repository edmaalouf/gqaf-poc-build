---
name: animations
description: Flutter animation guidance for building smooth, accessible transitions with appropriate implicit or explicit animations.
---

# Animations — Flutter

You are an expert in Flutter animations for building cross-platform apps with Flutter.

## Core Philosophy

Flutter's animation system is designed around a progressive complexity model. For simple transitions -- a color change, a size change, a fade -- implicit animation widgets (`AnimatedContainer`, `AnimatedOpacity`, `AnimatedSwitcher`) handle everything automatically. You set the target value, and the widget animates to it. No controller, no ticker, no dispose. When you need precise control -- play, pause, reverse, synchronize multiple properties -- explicit animations with `AnimationController` give you full access to the animation lifecycle. The right approach is to start with implicit animations and reach for explicit ones only when the implicit API cannot express what you need.

Every animation runs on the main isolate's render pipeline, which means a dropped frame is visible to the user as jank. The target is 60fps (or 120fps on high-refresh displays), giving you roughly 16ms per frame to compute layouts, paint widgets, and run animation ticks. Heavy computation in a `CustomPainter` or an `AnimatedBuilder` that rebuilds a large widget subtree will drop frames. `RepaintBoundary` isolates expensive subtrees so they repaint independently, and profiling with Flutter DevTools' timeline view reveals exactly where frame time is being spent.

The `vsync` parameter on `AnimationController` is not boilerplate -- it is a critical optimization. When a widget using `SingleTickerProviderStateMixin` is off-screen (e.g., in a tab that is not visible), the ticker pauses automatically, stopping the animation and saving CPU/battery. Without `vsync`, the animation continues ticking in the background, consuming resources for frames that no one can see.

## Anti-Patterns

- **Calling setState in a loop to animate values**: Manually calling `setState` 60 times per second to increment a counter or change a position creates jank because each call triggers a full widget rebuild. Use `AnimationController` or implicit animation widgets, which are integrated with Flutter's rendering pipeline and handle frame timing correctly.

- **Forgetting the key on AnimatedSwitcher children**: `AnimatedSwitcher` detects that its child changed by comparing widget keys. If two children have the same type and no explicit key, `AnimatedSwitcher` treats them as the same widget and does not animate. Always provide a `ValueKey` that changes when the content changes.

- **Using TickerProviderStateMixin when SingleTickerProviderStateMixin suffices**: `TickerProviderStateMixin` (plural) supports multiple tickers and is slightly less efficient. When a widget has exactly one `AnimationController`, use `SingleTickerProviderStateMixin`. This is not just a style preference -- it avoids unnecessary overhead.

- **Not disposing AnimationControllers**: An undisposed `AnimationController` continues to schedule frame callbacks after its widget has been removed from the tree, causing "called on a disposed widget" errors or memory leaks. Always call `_controller.dispose()` in the `dispose()` method.

- **Running expensive CustomPainter work without RepaintBoundary**: A `CustomPainter` that paints a complex path or shader on every frame causes the entire parent subtree to repaint. Wrapping the `CustomPaint` in a `RepaintBoundary` isolates its repainting from the rest of the widget tree, keeping other widgets from being unnecessarily repainted.

## Overview

Flutter's animation system ranges from zero-code implicit animations to fully custom explicit animations. This skill covers implicit widgets for simple transitions, `AnimationController` for precise control, staggered animations, Hero transitions, and performance considerations.

## Core Concepts

### Implicit Animations

Implicit animation widgets automatically animate between old and new values. No controller needed.

```dart
AnimatedContainer(
  duration: const Duration(milliseconds: 300),
  curve: Curves.easeInOut,
  width: isExpanded ? 300 : 100,
  height: isExpanded ? 200 : 100,
  decoration: BoxDecoration(
    color: isSelected ? Colors.blue : Colors.grey.shade200,
    borderRadius: BorderRadius.circular(isExpanded ? 16 : 8),
  ),
  child: const Center(child: Text('Tap me')),
)
```

Common implicit widgets: `AnimatedOpacity`, `AnimatedAlign`, `AnimatedPadding`, `AnimatedPositioned`, `AnimatedSwitcher`, `AnimatedCrossFade`.

### AnimatedSwitcher for Widget Transitions

```dart
AnimatedSwitcher(
  duration: const Duration(milliseconds: 300),
  transitionBuilder: (child, animation) {
    return FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0.0, 0.1),
          end: Offset.zero,
        ).animate(animation),
        child: child,
      ),
    );
  },
  child: Text(
    '$counter',
    key: ValueKey<int>(counter), // key change triggers the animation
    style: Theme.of(context).textTheme.displayMedium,
  ),
)
```

### Explicit Animations with AnimationController

Use when you need to play, pause, reverse, or repeat animations.

```dart
class PulsingDot extends StatefulWidget {
  const PulsingDot({super.key});

  @override
  State<PulsingDot> createState() => _PulsingDotState();
}

class _PulsingDotState extends State<PulsingDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _scaleAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 800),
      vsync: this,
    )..repeat(reverse: true);

    _scaleAnimation = Tween<double>(begin: 0.8, end: 1.2).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ScaleTransition(
      scale: _scaleAnimation,
      child: Container(
        width: 16,
        height: 16,
        decoration: const BoxDecoration(
          color: Colors.green,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}
```

### Tween and CurvedAnimation

```dart
final colorTween = ColorTween(begin: Colors.red, end: Colors.blue);
final curvedAnimation = CurvedAnimation(
  parent: _controller,
  curve: Curves.elasticOut,
);
final colorAnimation = colorTween.animate(curvedAnimation);
```

## Implementation Patterns

### Staggered Animations

```dart
class StaggeredListAnimation extends StatefulWidget {
  const StaggeredListAnimation({super.key, required this.items});
  final List<String> items;

  @override
  State<StaggeredListAnimation> createState() => _StaggeredListAnimationState();
}

class _StaggeredListAnimationState extends State<StaggeredListAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: Duration(milliseconds: 200 * widget.items.length),
      vsync: this,
    )..forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: widget.items.length,
      itemBuilder: (context, index) {
        final start = index / widget.items.length;
        final end = (index + 1) / widget.items.length;
        final animation = Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(
          CurvedAnimation(
            parent: _controller,
            curve: Interval(start, end, curve: Curves.easeOut),
          ),
        );
        return SlideTransition(
          position: animation,
          child: FadeTransition(
            opacity: CurvedAnimation(
              parent: _controller,
              curve: Interval(start, end),
            ),
            child: ListTile(title: Text(widget.items[index])),
          ),
        );
      },
    );
  }
}
```

### Hero Animations

```dart
// Source screen
GestureDetector(
  onTap: () => context.push('/detail/${product.id}'),
  child: Hero(
    tag: 'product-${product.id}',
    child: ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.network(product.imageUrl, fit: BoxFit.cover),
    ),
  ),
)

// Destination screen
Hero(
  tag: 'product-${product.id}',
  child: Image.network(product.imageUrl, fit: BoxFit.cover),
)
```

### Custom Animated Painter

```dart
class WaveAnimation extends StatefulWidget {
  const WaveAnimation({super.key});

  @override
  State<WaveAnimation> createState() => _WaveAnimationState();
}

class _WaveAnimationState extends State<WaveAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(seconds: 2),
      vsync: this,
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          painter: WavePainter(progress: _controller.value),
          size: const Size(double.infinity, 100),
        );
      },
    );
  }
}

class WavePainter extends CustomPainter {
  WavePainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.blue.withOpacity(0.5)
      ..style = PaintingStyle.fill;
    final path = Path();
    path.moveTo(0, size.height);
    for (double x = 0; x <= size.width; x++) {
      final y = size.height * 0.5 +
          sin((x / size.width * 2 * pi) + (progress * 2 * pi)) * 20;
      path.lineTo(x, y);
    }
    path.lineTo(size.width, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(WavePainter oldDelegate) => oldDelegate.progress != progress;
}
```

## Best Practices

- **Start with implicit animations.** If `AnimatedFoo` exists for your property, use it before reaching for `AnimationController`.
- **Always dispose controllers** in `dispose()` to prevent memory leaks and frame callbacks after the widget is gone.
- **Use `vsync: this`** with `TickerProviderStateMixin` to pause animations when the widget is not visible, saving battery.
- **Prefer `Transform` over `AnimatedContainer` for layout-independent changes** (rotation, scale) — `Transform` does not trigger a relayout.
- **Keep animations under 300-400ms** for UI transitions. Longer durations feel sluggish.

## Common Pitfalls

- **Animating in `build` without a controller**: Calling `setState` in a loop to animate causes jank. Always use `AnimationController` or implicit widgets.
- **Forgetting the `key` on `AnimatedSwitcher` children**: Without a changing key, `AnimatedSwitcher` does not know the child changed and will not animate.
- **Running heavy animations on the main isolate**: Complex `CustomPainter` or shader work can drop frames. Profile with DevTools and consider `RepaintBoundary`.
- **Using `TickerProviderStateMixin` (plural) when only one controller exists**: Use `SingleTickerProviderStateMixin` for a single controller — it is more efficient.
- **Hardcoding durations for different platforms**: iOS users expect different animation timing than Android. Consider platform-aware duration constants.
