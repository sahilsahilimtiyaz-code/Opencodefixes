/// The AI Team's two one-time moments (motion spec slice D,
/// docs/design/motion-and-illustration-2026-09-25.md):
///
/// - [TeamMergedCelebration]: a task's Overview celebrates once when the
///   task is merged — the first time the person sees it merged, never
///   again for that task. Remembered per profile across restarts under
///   `oc.orchestration.<profileId>.celebrated`, which the profile deletion
///   sweep (`ProfileStore.profileScopedPreferenceKeys`) and turning the
///   plugin off (`OrchestrationStore.sweep`) both remove.
/// - [TeamNeedsYouLabel]: the "Needs you" heading, with an agent that peeks
///   over the block below and waves once when a question first appears in
///   this session; later it stands still, raised hand and all. Never a
///   loop.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../kit/kit_illustration.dart';
import '../kit/kit_motion.dart';
import '../kit/motion/kit_reveal.dart';
import '../kit/kit_text.dart';
import '../kit/kit_tokens.dart';
import '../kit/scenes/team_scenes.dart';

/// Which merged tasks have had their celebration, per profile.
abstract final class TeamCelebrations {
  /// The preference holding a profile's celebrated task ids.
  static String keyFor(String profileId) =>
      'oc.orchestration.$profileId.celebrated';

  /// The most recent ids kept; older tasks are long off the host's list.
  static const keep = 100;

  static final _session = <String, Set<String>>{};

  /// True the first time it is asked about [runId] for [profileId], ever;
  /// false after (this session or a later one). Claims the id at once, so
  /// two Overviews built together cannot both celebrate.
  static Future<bool> claim(String profileId, String runId) async {
    final seen = _session.putIfAbsent(profileId, () => <String>{});
    if (!seen.add(runId)) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = keyFor(profileId);
      final stored = prefs.getStringList(key) ?? const <String>[];
      if (stored.contains(runId)) return false;
      final next = [...stored, runId];
      await prefs.setStringList(
        key,
        next.length > keep ? next.sublist(next.length - keep) : next,
      );
    } catch (_) {
      // No preference store (a test without one): remembered this session.
    }
    return true;
  }

  /// Forgets this session's memory (a restart, in tests).
  @visibleForTesting
  static void forgetSession() => _session.clear();
}

/// The celebration at the head of a merged task's Overview: shown once per
/// task ([TeamCelebrations]), including when the task merges while the
/// Overview is open. Nothing otherwise.
class TeamMergedCelebration extends StatefulWidget {
  const TeamMergedCelebration({
    super.key,
    required this.profileId,
    required this.runId,
    required this.merged,
  });

  final String profileId;
  final String runId;

  /// The task is done and its work landed.
  final bool merged;

  /// The drawing's width; its height follows [TeamMergedScene.box].
  static const drawingWidth = 176.0;

  @override
  State<TeamMergedCelebration> createState() => _TeamMergedCelebrationState();
}

class _TeamMergedCelebrationState extends State<TeamMergedCelebration> {
  bool _show = false;
  bool _asked = false;

  @override
  void initState() {
    super.initState();
    _ask();
  }

  @override
  void didUpdateWidget(TeamMergedCelebration old) {
    super.didUpdateWidget(old);
    if (old.runId != widget.runId) {
      _show = false;
      _asked = false;
    }
    _ask();
  }

  void _ask() {
    if (_asked || !widget.merged) return;
    _asked = true;
    // Best-effort celebration: never let a storage hiccup fail the frame.
    TeamCelebrations.claim(
      widget.profileId,
      widget.runId,
    ).then((celebrate) {
      if (celebrate && mounted) setState(() => _show = true);
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    // It unfolds into place when the task merges while the Overview is
    // open, then plays for a celebration's length (design standard §10).
    return KitReveal(
      child: !_show
          ? null
          : Padding(
              padding: EdgeInsetsDirectional.only(
                bottom: KitTokens.of(context).space3,
              ),
              child: const Align(
                alignment: AlignmentDirectional.centerStart,
                child: KitIllustration(
                  key: ValueKey('team-run-celebration'),
                  scene: TeamMergedScene(),
                  width: TeamMergedCelebration.drawingWidth,
                  entranceDuration: KitMotion.celebration,
                ),
              ),
            ),
    );
  }
}

/// The "Needs you" section heading with its nudge: an agent peeking over
/// the block below. It waves the first time any of [gateIds] shows in this
/// session, and stands still with its hand up after that.
class TeamNeedsYouLabel extends StatefulWidget {
  const TeamNeedsYouLabel(
    this.text, {
    super.key,
    required this.profileId,
    required this.gateIds,
    this.padding,
  });

  final String text;
  final String profileId;

  /// The questions the block below shows.
  final List<String> gateIds;

  /// The section label's padding; its bottom is the gap to the block.
  final EdgeInsets? padding;

  /// The nudge's width; its height follows [TeamNudgeScene.box].
  static const drawingWidth = 42.0;

  static final _nudged = <String>{};

  /// Forgets which questions were nudged (a restart, in tests).
  @visibleForTesting
  static void forgetSession() => _nudged.clear();

  @override
  State<TeamNeedsYouLabel> createState() => _TeamNeedsYouLabelState();
}

/// How far the nudge's foot reaches below the label's row, in dp.
const _tuck = 5.0;

class _TeamNeedsYouLabelState extends State<TeamNeedsYouLabel> {
  /// Bumped when a new question arrives, so the nudge plays for it.
  int _wave = 0;
  bool _fresh = false;

  @override
  void initState() {
    super.initState();
    _fresh = _note();
  }

  @override
  void didUpdateWidget(TeamNeedsYouLabel old) {
    super.didUpdateWidget(old);
    if (_note()) {
      _fresh = true;
      _wave += 1;
    }
  }

  /// Records the questions shown; true when one is new this session.
  bool _note() {
    var fresh = false;
    for (final id in widget.gateIds) {
      if (TeamNeedsYouLabel._nudged.add('${widget.profileId}/$id')) {
        fresh = true;
      }
    }
    return fresh;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = KitTokens.of(context);
    final padding =
        widget.padding ??
        EdgeInsets.fromLTRB(
          tokens.gutter,
          tokens.space6,
          tokens.gutter,
          tokens.labelGap,
        );
    final box = const TeamNudgeScene().box;
    final height = TeamNeedsYouLabel.drawingWidth * box.height / box.width;
    return Padding(
      padding: padding.copyWith(bottom: 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: padding.bottom),
              child: Semantics(
                header: true,
                child: KitText(widget.text, role: KitTextRole.label),
              ),
            ),
          ),
          // Takes no height of its own: the drawing rises above the label's
          // line, and its foot tucks behind the block's top edge (the
          // block's 4 dp margin, then just under its border), so the agent
          // peeks over it. An unclipped stack draws it outside the gap's
          // box, where the label row does not grow for it.
          SizedBox(
            width: TeamNeedsYouLabel.drawingWidth,
            height: padding.bottom,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                PositionedDirectional(
                  start: 0,
                  bottom: -_tuck,
                  width: TeamNeedsYouLabel.drawingWidth,
                  height: height,
                  child: KitIllustration(
                    key: ValueKey('team-needs-you-nudge-$_wave'),
                    scene: const TeamNudgeScene(),
                    width: TeamNeedsYouLabel.drawingWidth,
                    animateEntrance: _fresh,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
