# KitChatGlowFrame — frozen API

Group: chat. New part: the chat surface wearing the run.

## Purpose

While the agent works — thinking, coding, writing — a conic rainbow sweep
loops the chat's frame: a faint full-perimeter ring with one bright comet
head and its halo travelling it. Idle (no live turn) the frame paints
nothing at all. It is the chat-level sibling of the composer's living edge:
the composer says what the run is doing in words, the frame says the chat
is alive at a glance.

## File

`lib/ui/kit/chat/kit_chat_glow.dart` (new), exported from `kit.dart`.

## Public API

```dart
/// A frame that glows while the agent runs: `live` is the chat's running
/// turn ([KitTurnLive]), null when nothing runs. The child keeps its size;
/// the sweep paints over it without taking space or semantics.
class KitChatGlowFrame extends StatefulWidget {
  const KitChatGlowFrame({super.key, required this.child, this.live});

  final Widget child;
  final KitTurnLive? live;
}
```

Host: `chat_screen.dart` wraps `KitComposer.layer(...)` with the frame,
driven by `_live?.live` — the same live value the transcript's live line
and the composer read. Null means idle, and the frame stays dark.

## Behaviour

- **Full motion**: the ring sweeps. Speed follows the turn's activity —
  thinking rests at `KitMotion.chatGlowThinkingLapsPerSecond`, writing runs
  up to `KitMotion.chatGlowMaxLapsPerSecond` with `KitTurnLive.pace`,
  tool work sits between, `waitingForYou` dims to a slow drift. Speed and
  brightness ease (`chatGlowSpeedEase`, `chatGlowFade`); nothing jerks when
  a turn starts or ends.
- **Calm**: a static ring breathing slowly, no travel.
- **Off, reduced motion, tests**: paints nothing; the ticker never starts.
- The ticker only runs while there is something to show and stops itself
  once the glow has eased out; it mutes with the route (`TickerMode`).

## Look

- The outline hugs the child (`cardRadius`, 1 dp inset): base ring at low
  alpha, comet head with halo and a near-white core.
- Colours are computed, never literals (G17): the hue wheel walks red,
  orange, yellow, light green, blue, purple and pink, with softening dips
  that pass through near-white (`chatGlowColorAt`).
- Technique mirrors the composer's edge painter: rounded-rect outline,
  `PathMetric` segments, blurred stroke pieces — no `Gradient` widgets, no
  `BoxShadow`, no `ImageFilter`.
- Decorative: wrapped in `ExcludeSemantics`; never a status carrier.

## Rules

STATE-16 (the kit owns transcript looks), MOT-1 (timings in `KitMotion`),
LOOK-1 (no literal colours), LOOK-14 (decorative glow only, text stays
opaque), A11Y-5 (out of semantics), KIT-9 (token radius).

## Tests required

`test/kit/kit_chat_glow_test.dart`: idle paints nothing and starts no loop;
a live turn keeps the child through thinking/writing/idle; motion off and
calm keep the child; the glow carries no semantics; the hue wheel lands on
red/yellow/green/blue/pink and dips near white; the speed ladder reads
writing > thinking > 0.
