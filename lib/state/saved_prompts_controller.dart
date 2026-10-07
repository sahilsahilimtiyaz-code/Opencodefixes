import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'prompt_shelf.dart';
import 'saved_prompt_safety.dart';

export '../api/models.dart' show PromptAttachment;
export 'prompt_shelf.dart' show StashedPrompt;
export 'review_handoff.dart'
    show ReviewReference, ReviewReferenceKind, ReviewReferenceScope;

/// Adapter owned by the conversation's state owner, bound to one profile,
/// conversation and location for its lifetime. [replace] must persist before
/// publishing, reject a removed profile, and preserve all attachment/reference
/// content. A refused write must leave [value] unchanged.
abstract interface class SavedPromptComposer {
  StashedPrompt get value;
  Future<void> replace(StashedPrompt value);
}

/// A one-use, memory-only Undo. [undo] refuses stale composer edits or profile
/// removal instead of overwriting newer work. A storage failure can be retried.
class SavedPromptUndo {
  SavedPromptUndo._(this._action);

  /// An Undo for a saved prompt kept outside a profile shelf (a removed
  /// server's queued prompts), with the same one-use rules.
  SavedPromptUndo.kept(Future<void> Function() action) : this._(action);
  final Future<void> Function() _action;
  bool _used = false;
  bool _running = false;

  Future<void> undo() async {
    if (_used || _running) throw StateError('Undo is no longer available');
    _running = true;
    try {
      await _action();
      _used = true;
    } finally {
      _running = false;
    }
  }
}

/// Saved-prompt actions without confirmation dialogs. Use a single controller
/// and shelf per profile; dispose/invalidate it BEFORE profile deletion begins.
/// Restoring keeps the saved source reusable, matching the existing shelf.
class SavedPromptsController extends ChangeNotifier {
  SavedPromptsController({
    required this.profileID,
    required this.shelf,
    required this.profileExists,
  }) {
    if (profileID.isEmpty) throw ArgumentError('Missing profile');
    savedPromptIdentity(profileID);
  }

  final String profileID;
  final PromptShelfStore shelf;
  final bool Function(String profileID) profileExists;
  bool _busy = false;
  bool _active = true;
  bool get busy => _busy;
  List<StashedPrompt> get prompts {
    _check();
    return shelf.stashes(profileID);
  }

  void _check() {
    if (!_active || !profileExists(profileID)) {
      throw StateError('Saved prompt profile is unavailable');
    }
  }

  Future<T> _change<T>(Future<T> Function() action) async {
    _check();
    if (_busy) throw StateError('Saved prompt action is in progress');
    _busy = true;
    notifyListeners();
    try {
      return await action();
    } finally {
      _busy = false;
      if (_active) notifyListeners();
    }
  }

  Future<void> save(StashedPrompt prompt) => _change(
    () => shelf.stash(
      profileID,
      sanitizeSavedPrompt(prompt),
      checkCurrent: _check,
    ),
  );

  Future<StashedPrompt> _materialize(
    String id, {
    required bool sameLocation,
    bool partial = false,
  }) async {
    final prompt = prompts.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('The saved prompt is gone'),
    );
    if (!sameLocation && prompt.locationBound) {
      throw StateError('Saved prompt belongs to another location');
    }
    final recovered = await shelf.restoreAttachments(
      profileID,
      id,
      sameLocation: sameLocation,
      checkCurrent: _check,
    );
    if (recovered.unavailable.isNotEmpty && !partial) {
      throw StateError('Saved prompt attachments are unavailable');
    }
    return sanitizeSavedPrompt(
      StashedPrompt(
        id: prompt.id,
        text: prompt.text,
        createdAt: prompt.createdAt,
        directory: prompt.directory,
        workspace: prompt.workspace,
        attachments: List.unmodifiable(recovered.attachments),
        references: List.unmodifiable(prompt.references),
      ),
    );
  }

  /// Removes now; keeps full attachment bytes in the Undo closure until the
  /// notice is dismissed. No persistent tombstone or hidden recovery queue.
  /// An attachment whose file is already gone does not block the delete;
  /// Undo brings back everything that could still be read.
  Future<SavedPromptUndo> delete(String id) => _change(() async {
    final original = await _materialize(id, sameLocation: true, partial: true);
    await shelf.remove(profileID, id, checkCurrent: _check);
    return SavedPromptUndo._(
      () =>
          _change(() => shelf.stash(profileID, original, checkCurrent: _check)),
    );
  });

  /// Replaces the conversation draft now and returns Undo for its exact prior
  /// content. Refuses partial attachment recovery and location-bound cross-
  /// project restores. The source remains saved, including after restart.
  Future<SavedPromptUndo> restore(
    String id, {
    required SavedPromptComposer composer,
    required bool sameLocation,
  }) => _change(() async {
    final replacement = await _materialize(id, sameLocation: sameLocation);
    final previous = StashedPrompt.fromJson(composer.value.toJson());
    if (jsonEncode(sanitizeSavedPrompt(previous).toJson()) !=
        jsonEncode(previous.toJson())) {
      throw StateError('The current draft must be sanitized before restoring');
    }
    _check();
    await composer.replace(replacement);
    _check();
    final installed = jsonEncode(composer.value.toJson());
    return SavedPromptUndo._(
      () => _change(() async {
        if (jsonEncode(composer.value.toJson()) != installed) {
          throw StateError('The conversation draft has changed');
        }
        await composer.replace(previous);
        _check();
      }),
    );
  });

  /// Call before the coordinator's existing profile deletion sweep. Outstanding
  /// Undo handles and in-flight shelf operations then refuse further writes.
  void invalidate() {
    _active = false;
  }

  @override
  void dispose() {
    invalidate();
    super.dispose();
  }
}
