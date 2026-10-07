// Behaviour tests for KitChatGlowFrame
// (docs/ux-system/kit-api/KitChatGlow.md "Tests required").
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/l10n/app_localizations.dart';
import 'package:opencode_mobile/state/effects.dart';
import 'package:opencode_mobile/ui/app_theme.dart';
import 'package:opencode_mobile/ui/kit/chat/kit_chat_glow.dart';
import 'package:opencode_mobile/ui/kit/chat/kit_turn.dart';
import 'package:opencode_mobile/ui/kit/kit_motion.dart';

import 'kit_motion_still.dart';

const _childKey = Key('glow-child');

Future<void> _pump(
  WidgetTester tester,
  Widget frame, {
  Size size = const Size(412, 915),
  KitEffects effects = KitEffects.defaults,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    KitEffectsScope(
      effects: effects,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox.expand(
            child: frame,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Widget _frame({KitTurnLive? live}) => KitChatGlowFrame(
  live: live,
  child: const SizedBox.expand(key: _childKey),
);

const _thinking = KitTurnLive(activity: KitTurnActivity.thinking);
const _writing = KitTurnLive(activity: KitTurnActivity.writing, pace: 1);

void main() {
  // Gate G8x (MOT-7): every kit.dart part registers reduced-motion samples
  // in its own test file. A running frame must settle after one pump under
  // both stillnesses, like an idle one.
  kitMotionStillTests(
    'KitChatGlowFrame',
    builds: {
      'idle': () => const KitChatGlowFrame(child: Text('Chat glow')),
      'running': () => const KitChatGlowFrame(
        live: KitTurnLive(activity: KitTurnActivity.thinking),
        child: Text('Chat glow'),
      ),
    },
    changes: {
      'run starts': KitMotionChange(
        build: () => const KitChatGlowFrame(child: Text('Chat glow')),
        act: (tester, stage) => stage.rebuild(
          const KitChatGlowFrame(
            live: KitTurnLive(activity: KitTurnActivity.writing),
            child: Text('Chat glow'),
          ),
        ),
        shows: 'Chat glow',
      ),
    },
  );

  group('KitChatGlowFrame (KitChatGlow.md)', () {
    testWidgets('idle paints nothing and starts no loop', (tester) async {
      await _pump(tester, _frame());
      expect(find.byKey(_childKey), findsOneWidget);
      // Loops stay off under flutter test; settling proves no ticker runs.
      await tester.pump(const Duration(seconds: 5));
      expect(find.byKey(_childKey), findsOneWidget);
    });

    testWidgets('a live turn keeps the child and settles', (tester) async {
      await _pump(tester, _frame(live: _thinking));
      expect(find.byKey(_childKey), findsOneWidget);
      await _pump(tester, _frame(live: _writing));
      expect(find.byKey(_childKey), findsOneWidget);
      await _pump(tester, _frame());
      expect(find.byKey(_childKey), findsOneWidget);
    });

    testWidgets('motion off and calm keep the child', (tester) async {
      await _pump(
        tester,
        _frame(live: _writing),
        effects: KitEffects.defaults.copyWith(motion: KitMotionLevel.off),
      );
      expect(find.byKey(_childKey), findsOneWidget);
      await _pump(
        tester,
        _frame(live: _thinking),
        effects: KitEffects.defaults.copyWith(motion: KitMotionLevel.calm),
      );
      expect(find.byKey(_childKey), findsOneWidget);
    });

    testWidgets('the glow carries no semantics of its own', (tester) async {
      await _pump(tester, _frame(live: _writing));
      expect(
        find.byWidgetPredicate(
          (w) => w is ExcludeSemantics && w.excluding,
        ),
        findsWidgets,
      );
    });
  });

  group('chatGlowColorAt (the hue wheel)', () {
    test('walks the rainbow: red, yellow, green, blue, pink', () {
      Color hsv(double h, double s) =>
          HSVColor.fromAHSV(1, h, s, 1).toColor();
      final red = HSVColor.fromAHSV(1, 0, 1, 1).toColor();
      final yellow = HSVColor.fromAHSV(1, 60, 1, 1).toColor();
      final green = HSVColor.fromAHSV(1, 120, 1, 1).toColor();
      final blue = HSVColor.fromAHSV(1, 240, 1, 1).toColor();
      // Ring positions 0, 1/6, 1/3, 2/3 land on red, yellow, green, blue.
      expect(chatGlowColorAt(0).hue(red), lessThan(15));
      expect(chatGlowColorAt(1 / 6).hue(yellow), lessThan(30));
      expect(chatGlowColorAt(1 / 3).hue(green), lessThan(45));
      expect(chatGlowColorAt(2 / 3).hue(blue), lessThan(45));
      expect(hsv(330, 1).hue(chatGlowColorAt(11 / 12)), lessThan(45));
    });

    test('softening dips pass near white somewhere', () {
      var palest = 1.0;
      for (var i = 0; i < 360; i++) {
        final s = HSVColor.fromColor(chatGlowColorAt(i / 360)).saturation;
        if (s < palest) palest = s;
      }
      expect(palest, lessThan(0.5));
    });

    test('speed ladder: writing fastest, thinking rests, all positive', () {
      expect(KitMotion.chatGlowMaxLapsPerSecond, greaterThan(0));
      expect(
        KitMotion.chatGlowMaxLapsPerSecond,
        greaterThan(KitMotion.chatGlowThinkingLapsPerSecond),
      );
      expect(KitMotion.chatGlowThinkingLapsPerSecond, greaterThan(0));
    });
  });
}

/// Circular distance between two hues in degrees.
extension on Color {
  double hue(Color other) {
    final a = HSVColor.fromColor(this).hue;
    final b = HSVColor.fromColor(other).hue;
    final d = (a - b).abs();
    return d > 180 ? 360 - d : d;
  }
}
