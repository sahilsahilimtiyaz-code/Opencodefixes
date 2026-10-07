// Gallery (gate G4) for KitChatGlowFrame
// (docs/ux-system/kit-api/KitChatGlow.md): the running frame at the spec's
// sizes, dark and light, plus 2.0 text. The sweep itself never moves here:
// ambient loops stay off under test, so the ticker never starts and the
// shots hold the running configuration still.
//
// Regenerate deliberately:
//   flutter test --update-goldens test/goldens/kit/kit_chat_glow_golden_test.dart
// and look at every changed image before committing it.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opencode_mobile/ui/kit/chat/kit_chat_glow.dart';
import 'package:opencode_mobile/ui/kit/chat/kit_turn.dart';
import 'package:opencode_mobile/ui/kit/kit_text.dart';

import 'kit_gallery.dart';

Widget _working() => KitChatGlowFrame(
  live: const KitTurnLive(activity: KitTurnActivity.thinking),
  child: Padding(
    padding: const EdgeInsets.all(24),
    child: Center(
      child: KitText(
        'The agent is working',
        role: KitTextRole.rowTitle,
      ),
    ),
  ),
);

void main() {
  setUpAll(loadKitGalleryFonts);

  for (final light in [false, true]) {
    final mode = light ? 'light' : 'dark';

    for (final size in [const Size(412, 915), const Size(1280, 800)]) {
      testWidgets('working · ${kitGallerySize(size)} · $mode', (tester) async {
        await kitGalleryPart(
          tester,
          name: kitGalleryName(
            // The part snake, not the file: KitChatGlowFrame.
            'kit_chat_glow_frame_working',
            size,
            light: light,
          ),
          size: size,
          light: light,
          child: _working(),
        );
      });
    }

    testWidgets('working · 2.0 text · $mode', (tester) async {
      const size = Size(412, 915);
      await kitGalleryPart(
        tester,
        name: kitGalleryName(
          'kit_chat_glow_frame_working',
          size,
          light: light,
          text2: true,
        ),
        size: size,
        light: light,
        textScale: 2,
        child: _working(),
      );
    });
  }
}
