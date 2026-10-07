// KitChatGlowFrame: the chat surface wearing the run. While the agent is
// working — thinking, coding, writing — a conic rainbow sweep loops the
// chat's frame: a faint full-perimeter ring with one bright comet head and
// its halo travelling it. Idle (no live turn) paints nothing at all.
//
// The sweep is decorative and left out of semantics; the turn's live line
// and the composer's caption stay the readable status. The ticker only runs
// while there is something to show, and stops with the route (TickerMode)
// and the app in the background.
//
// Motion levels mirror the composer's living edge: Full travels, Calm only
// breathes a static ring, Off and reduced motion stay dark. Tests keep loops
// off, like every loop, so the frame never starts a ticker there.
//
// Colours are computed, never literals (G17): the hue wheel walks red,
// orange, yellow, light green, blue, purple and pink, with periodic
// softening dips that pass through near-white.
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../kit_effects.dart';
import '../kit_motion.dart';
import '../kit_tokens.dart';
import 'kit_turn.dart';

/// The mutable sweep state, painted by [_ChatGlowPainter], stepped by the
/// frame's ticker.
class _GlowSweep {
  /// Head position along the outline, 0..1 of one lap.
  double phase = 0;

  /// Laps per second.
  double speed = 0;

  /// 0..1: eases in when a turn starts, out when it ends.
  double bright = 0;

  /// Seconds, for the calm breathing.
  double time = 0;
}

/// A frame that glows while the agent runs: `live` is the chat's running
/// turn ([KitTurnLive]), null when nothing runs. The child keeps its size;
/// the sweep paints over it without taking space or semantics.
class KitChatGlowFrame extends StatefulWidget {
  const KitChatGlowFrame({super.key, required this.child, this.live});

  final Widget child;
  final KitTurnLive? live;

  @override
  State<KitChatGlowFrame> createState() => _KitChatGlowFrameState();
}

class _KitChatGlowFrameState extends State<KitChatGlowFrame>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker(_step);
  final _sweep = _GlowSweep();
  final _repaint = ValueNotifier<int>(0);
  Duration _last = Duration.zero;

  /// Full animates the sweep; Calm only breathes it. Off, reduced motion
  /// and tests keep it dark. Only Full lets it travel.
  bool get _loops =>
      KitMotion.loops &&
      !KitMotion.reduced(context) &&
      KitEffects.of(context).motion != KitMotionLevel.off;
  bool get _travels =>
      _loops && KitEffects.of(context).motion == KitMotionLevel.full;

  @override
  void initState() {
    super.initState();
    if (widget.live != null) _wake();
  }

  @override
  void didUpdateWidget(KitChatGlowFrame old) {
    super.didUpdateWidget(old);
    if (widget.live != null) {
      _wake();
    } else if (_sweep.bright > 0.01 && _loops) {
      // The turn ended: ease the glow out, then the ticker stops itself.
      _wake();
    } else {
      _sweep.bright = 0;
      _sweep.speed = 0;
      _repaint.value++;
    }
  }

  void _wake() {
    if (!_ticker.isActive) {
      _last = Duration.zero;
      _ticker.start();
    }
  }

  void _step(Duration elapsed) {
    final dt = _last == Duration.zero
        ? 0.016
        : ((elapsed - _last).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _last = elapsed;
    final s = _sweep;
    s.time += dt;
    final k =
        1 - math.exp(-dt / (KitMotion.chatGlowFade.inMilliseconds / 1500));
    final kSpeed =
        1 -
        math.exp(-dt / (KitMotion.chatGlowSpeedEase.inMilliseconds / 1500));
    final live = widget.live;
    var speedT = 0.0;
    var brightT = 0.0;
    // Off, reduced motion and tests stay dark even mid-turn: the targets
    // hold at zero and the ticker below stops itself.
    if (live != null && _loops) {
      final max = KitMotion.chatGlowMaxLapsPerSecond;
      final rest = KitMotion.chatGlowThinkingLapsPerSecond;
      switch (live.activity) {
        case KitTurnActivity.writing:
          final p = live.pace.clamp(0.0, 1.0);
          speedT = rest + (max - rest) * p;
          brightT = 0.75 + 0.25 * p;
        case KitTurnActivity.working:
          speedT = rest * 1.5;
          brightT = 0.7;
        case KitTurnActivity.waitingForYou:
          speedT = rest * 0.6;
          brightT = 0.35;
        case KitTurnActivity.sending:
        case KitTurnActivity.waitingForServer:
        case KitTurnActivity.waitingForModel:
        case KitTurnActivity.thinking:
          speedT = rest;
          brightT = 0.65;
      }
    }
    if (!_travels) speedT = 0;
    s.speed += (speedT - s.speed) * kSpeed;
    s.bright += (brightT - s.bright) * k;
    s.phase = (s.phase + s.speed * dt) % 1;
    _repaint.value++;
    if ((live == null || !_loops) && s.bright < 0.01) {
      s.bright = 0;
      s.speed = 0;
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _repaint.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final radius = KitTokens.of(context).cardRadius;
    return ExcludeSemantics(
      child: CustomPaint(
        foregroundPainter: _ChatGlowPainter(
          sweep: _sweep,
          radius: radius,
          travels: _travels,
          repaint: _repaint,
        ),
        child: widget.child,
      ),
    );
  }
}

/// The hue-wheel colour at ring position [u] (0..1): red, orange, yellow,
/// light green, blue, purple, pink, with softening dips that pass through
/// near-white so the ring carries white too.
@visibleForTesting
Color chatGlowColorAt(double u) {
  final hue = ((u % 1) * 360 + 360) % 360;
  final soft = 0.5 + 0.5 * math.sin(u * math.pi * 2 * 3 + 1.2);
  final saturation = 0.3 + 0.6 * soft;
  return HSVColor.fromAHSV(1, hue, saturation.clamp(0.0, 1.0), 1).toColor();
}

class _ChatGlowPainter extends CustomPainter {
  _ChatGlowPainter({
    required this.sweep,
    required this.radius,
    required this.travels,
    required super.repaint,
  });

  final _GlowSweep sweep;
  final double radius;
  final bool travels;

  static const _inset = 1.0;
  static const _segments = 64;

  /// Share of the perimeter the comet head covers.
  static const _headWindow = 0.24;

  Path _outline(Size size) {
    final r = math.max(radius - _inset, 1.0);
    final rect = Rect.fromLTWH(
      _inset,
      _inset,
      size.width - 2 * _inset,
      size.height - 2 * _inset,
    );
    return Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
  }

  static double _around(double u) => ((u % 1) + 1) % 1;

  @override
  void paint(Canvas canvas, Size size) {
    if (sweep.bright < 0.01) return;
    if (size.width <= 4 || size.height <= 4) return;
    final metric = _outline(size).computeMetrics().first;
    final length = metric.length;
    if (length <= 0) return;
    if (!travels) {
      // Calm: a static ring breathing slowly, no travel.
      final breath =
          0.5 + 0.5 * math.sin(sweep.time * 2 * math.pi / 4.5);
      final alpha = sweep.bright * (0.10 + 0.06 * breath);
      for (var i = 0; i < _segments; i++) {
        _piece(
          canvas,
          metric,
          length,
          i / _segments,
          (i + 1) / _segments,
          chatGlowColorAt(i / _segments).withValues(alpha: alpha),
          2,
          null,
        );
      }
      return;
    }
    // Full: the faint full ring, then the travelling comet head.
    for (var i = 0; i < _segments; i++) {
      final u = i / _segments;
      _piece(
        canvas,
        metric,
        length,
        u,
        (i + 1) / _segments,
        chatGlowColorAt(u).withValues(alpha: 0.16 * sweep.bright),
        2,
        null,
      );
    }
    for (var i = 0; i < _segments; i++) {
      final u = (i + 0.5) / _segments;
      var d = (u - sweep.phase).abs();
      d = math.min(d, 1 - d);
      if (d > _headWindow) continue;
      final t = 1 - d / _headWindow;
      final fall = t * t;
      final color = chatGlowColorAt(u);
      // Halo first (under), then the line, then its near-white core.
      _piece(
        canvas,
        metric,
        length,
        u - 0.5 / _segments,
        u + 0.5 / _segments,
        color.withValues(alpha: sweep.bright * 0.35 * fall),
        10,
        const MaskFilter.blur(BlurStyle.normal, 7),
      );
      _piece(
        canvas,
        metric,
        length,
        u - 0.5 / _segments,
        u + 0.5 / _segments,
        color.withValues(
          alpha: sweep.bright * (0.25 + 0.6 * fall).clamp(0.0, 1.0),
        ),
        3,
        null,
      );
      _piece(
        canvas,
        metric,
        length,
        u - 0.25 / _segments,
        u + 0.25 / _segments,
        HSVColor.fromAHSV(
          1,
          ((u % 1) * 360 + 360) % 360,
          0.08,
          1,
        ).toColor().withValues(alpha: sweep.bright * 0.8 * fall),
        2,
        null,
      );
    }
  }

  static void _piece(
    Canvas canvas,
    PathMetric metric,
    double length,
    double from,
    double to,
    Color color,
    double width,
    MaskFilter? blur,
  ) {
    var a = _around(from) * length;
    var b = _around(to) * length;
    if (a == b) return;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = width
      ..color = color
      ..maskFilter = blur;
    if (b < a) {
      final t = a;
      a = 0;
      canvas.drawPath(metric.extractPath(a, b), paint);
      canvas.drawPath(metric.extractPath(t, length), paint);
    } else {
      canvas.drawPath(metric.extractPath(a, b), paint);
    }
  }

  @override
  bool shouldRepaint(_ChatGlowPainter old) =>
      old.sweep != sweep ||
      old.radius != radius ||
      old.travels != travels;
}
