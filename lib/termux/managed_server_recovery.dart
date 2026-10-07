import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../state/automation_policy.dart';
import 'bridge.dart';

typedef ManagedRestartRecorder =
    Future<bool> Function({
      required String profileId,
      required String eventId,
      required DateTime at,
    });

enum ManagedRecoveryPhase {
  disabled,
  waitingForServer,
  monitoring,
  waitingToRetry,
  restarting,
  paused,
  exhausted,
}

enum ManagedRecoveryError {
  settingsUnreadable,
  enableFailed,
  ownershipChanged,
  uncertainResult,
}

/// One foreground recovery owner per managed Termux installation. The durable
/// budget is never reset by reconnects, successful restarts or app recreation.
class ManagedServerRecovery extends ChangeNotifier with WidgetsBindingObserver {
  ManagedServerRecovery._(
    this.prefs,
    this.profileID,
    this._now,
    this._onRestart,
  ) {
    _policy = AutomationPolicyController.forProfile(prefs, profileID);
    _policy.addListener(_policyChanged);
    _restore();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _initialization = _migrateLegacyPreference();
    _schedule();
  }

  static const maxAttempts = 3;
  static const backoff = [
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 45),
  ];
  static final _instances =
      Map<SharedPreferences, Map<String, ManagedServerRecovery>>.identity();
  static final _owners = Map<SharedPreferences, String>.identity();
  static final _knownProfiles = Map<SharedPreferences, Set<String>>.identity();
  static final _retiredProfiles =
      Map<SharedPreferences, Set<String>>.identity();
  // Deletion admission survives disposal of the last runtime facade. A saved
  // profile is reopened only by syncProfiles after the deletion transaction.
  static final _deletingProfiles =
      Map<SharedPreferences, Set<String>>.identity();
  // Recovery records share an installation budget. Serialize its whole write
  // (including alias mirrors), so deletion can drain every writer of one ID.
  static final _preferenceWrites =
      Map<SharedPreferences, Future<void>>.identity();
  static final _runtimes =
      Map<SharedPreferences, Map<String, TermuxRuntime>>.identity();
  // Registration belongs to the connection scope, even before the person
  // enables recovery and a UI first creates the per-installation owner.
  static final _recorders =
      Map<SharedPreferences, ManagedRestartRecorder>.identity();
  // A replacement owner must not re-arm before a previous scope's revocation
  // has completed. Revocation itself never waits for a slow startup callback.
  static final _revocations = Map<SharedPreferences, Future<void>>.identity();
  static String preferenceKey(String profileID) =>
      'oc.managedServerRecovery.$profileID';

  static ManagedServerRecovery forProfile(
    SharedPreferences prefs,
    String profileID, {
    DateTime Function()? now,
    ManagedRestartRecorder? onRestart,
  }) {
    if (onRestart != null) _recorders[prefs] = onRestart;
    final recorder = onRestart ?? _recorders[prefs];
    final profiles = _instances.putIfAbsent(prefs, () => {});
    final known = _knownProfiles[prefs];
    if (!_owners.containsKey(prefs) &&
        ((known == null && profiles.isEmpty) ||
            (known?.length == 1 && known!.contains(profileID)))) {
      _owners[prefs] = profileID;
    }
    final instance = profiles.putIfAbsent(
      profileID,
      () => ManagedServerRecovery._(
        prefs,
        profileID,
        now ?? DateTime.now,
        recorder,
      ),
    );
    if (recorder != null) instance._onRestart = recorder;
    if (now != null) instance._now = now;
    return instance;
  }

  static void syncProfiles(
    SharedPreferences prefs,
    Iterable<String> managedProfileIDs, {
    ManagedRestartRecorder? onRestart,
    Map<String, TermuxRuntime> runtimes = const {},
  }) {
    final ids = managedProfileIDs.toSet();
    if (ids.isEmpty) {
      disposeForPreferences(prefs);
      return;
    }
    _knownProfiles[prefs] = ids;
    final resumed = (_deletingProfiles[prefs] ?? {}).intersection(ids);
    _deletingProfiles[prefs]?.removeAll(ids);
    _retiredProfiles[prefs]?.removeAll(ids);
    _runtimes[prefs] = Map.of(runtimes);
    if (onRestart != null) _recorders[prefs] = onRestart;
    final profiles = _instances[prefs];
    for (final id in resumed) {
      final instance = profiles?[id];
      if (instance != null && !instance._disposed) {
        instance._admissionClosed = false;
        instance._notify();
        instance._schedule();
      }
    }
    for (final id in profiles?.keys.toList() ?? <String>[]) {
      if (!ids.contains(id)) profiles!.remove(id)?.dispose();
    }
    if (!ids.contains(_owners[prefs])) _owners.remove(prefs);
    if (!TermuxBridge.supported) return;
    // With multiple saved generations, only a retained owner or an explicit
    // manual start identifies whose policy controls this one installation.
    for (final id in ids) {
      forProfile(prefs, id, onRestart: onRestart);
    }
  }

  static void disposeForPreferences(SharedPreferences prefs) {
    _recorders.remove(prefs);
    for (final instance
        in _instances.remove(prefs)?.values ?? <ManagedServerRecovery>[]) {
      instance.dispose();
    }
    _owners.remove(prefs);
    _knownProfiles.remove(prefs);
    _runtimes.remove(prefs);
    _retiredProfiles.remove(prefs);
  }

  /// Admission closes synchronously, including when profile deletion has more
  /// async work ahead. Revocation then cancels a dispatched owned recovery.
  static Future<void> disableForProfile(
    SharedPreferences prefs,
    String profileID,
  ) {
    (_retiredProfiles[prefs] ??= {}).add(profileID);
    final current = _instances[prefs]?[profileID];
    if (current != null) {
      return current._disableForDeletion();
    }
    return _disableStored(prefs, profileID);
  }

  /// Deletion already pauses the automation policy owner. Revoke recovery
  /// without editing that policy: failed cleanup must retain the user's choice.
  static Future<void> prepareForProfileDeletion(
    SharedPreferences prefs,
    String profileID,
  ) async {
    (_deletingProfiles[prefs] ??= {}).add(profileID);
    (_retiredProfiles[prefs] ??= {}).add(profileID);
    final current = _instances[prefs]?[profileID];
    if (current != null) {
      current._admissionClosed = true;
      ++current._epoch;
      current._timer?.cancel();
      current._armed = false;
      current._notify();
      final revoking = current.ownsInstallation
          ? current._revokePermit()
          : Future<void>.value();
      try {
        await current._initialization;
      } finally {
        await revoking;
      }
      await current._inFlightCheck;
    } else {
      final raw = prefs.getString(preferenceKey(profileID));
      if (raw != null &&
          (_owners[prefs] == null || _owners[prefs] == profileID)) {
        try {
          final decoded = jsonDecode(raw);
          final token = decoded is Map ? decoded['token'] : null;
          if (token is String && token.isNotEmpty) {
            await TermuxBridge.run(
              TermuxBridge.recoveryControlScript(token, enable: false),
            );
          }
        } catch (_) {
          // Corrupt stored recovery: nothing safe to revoke.
        }
      }
    }
    await _preferenceWrites[prefs];
  }

  /// An intentional stop/runtime switch suspends this installation without
  /// changing the person's restart preference. Only an explicit successful
  /// manual start may adopt the next operation.
  static Future<void> suspendForProfile(
    SharedPreferences prefs,
    String profileID,
  ) async {
    final owner = _instances[prefs]?[_owners[prefs]];
    if (owner != null) await owner._suspend();
    final requested = forProfile(prefs, profileID);
    if (!identical(owner, requested)) await requested._suspend();
  }

  static Future<void> resumeAfterManualStartForProfile(
    SharedPreferences prefs,
    String profileID,
  ) async {
    if (_deletingProfiles[prefs]?.contains(profileID) ?? false) return;
    final requested = forProfile(prefs, profileID);
    final previous = _instances[prefs]?[_owners[prefs]];
    if (previous != null && !identical(previous, requested)) {
      await previous._suspend();
    }
    if (requested._cannotSave) return;
    requested.attempts = requested._sharedAttempts();
    requested._manuallySuspended = true;
    // Copy the installation budget before this profile gains admission.
    await requested._save();
    if (requested._cannotSave) return;
    _owners[prefs] = profileID;
    await requested._resumeAfterManualStart();
  }

  static Future<void> _disableStored(SharedPreferences prefs, String id) async {
    final raw = prefs.getString(preferenceKey(id));
    // Profiles outside this installation have no recovery to revoke. Do not
    // create or change their automation policy merely to delete the profile.
    if (raw == null) return;
    await AutomationPolicyController.forProfile(
      prefs,
      id,
    ).setBehavior(AutomationBehavior.restartPhoneServer, false);
    if (_deletingProfiles[prefs]?.contains(id) ?? false) return;
    final decoded = (() {
      try {
        return jsonDecode(raw);
      } catch (_) {
        return null;
      }
    })();
    if (decoded is! Map<String, dynamic>) return;
    final data = Map<String, dynamic>.from(decoded);
    data['enabled'] = false;
    final token = data['token'];
    final revoking = token is String && token.isNotEmpty
        ? TermuxBridge.run(
            TermuxBridge.recoveryControlScript(token, enable: false),
          ).then<void>((_) {})
        : Future<void>.value();
    // Observe revocation immediately even if the preference lane is blocked.
    unawaited(revoking.then<void>((_) {}, onError: (Object _) {}));
    try {
      await _serializePreferenceWrite(prefs, () async {
        if (_deletingProfiles[prefs]?.contains(id) ?? false) return;
        if (!await prefs.setString(preferenceKey(id), jsonEncode(data))) {
          throw StateError('Could not save recovery preference');
        }
      });
    } finally {
      await revoking;
    }
  }

  final SharedPreferences prefs;
  final String profileID;
  DateTime Function() _now;
  late final AutomationPolicyController _policy;
  ManagedRestartRecorder? _onRestart;
  String _unreportedOperation = '';
  DateTime? _confirmedAt;
  bool get _automationAllowed =>
      _policy.value.allows(AutomationBehavior.restartPhoneServer) &&
      _policy.value.allows(AutomationBehavior.pollRestartHealth);
  bool get enabled =>
      !_cannotSave &&
      !_admissionClosed &&
      !(_retiredProfiles[prefs]?.contains(profileID) ?? false) &&
      !_legacyMigrationPending &&
      _policy.value.allows(AutomationBehavior.restartPhoneServer);
  bool _admissionClosed = false;
  bool _legacyMigrationPending = false;
  bool? _legacyEnabled;
  late final Future<void> _initialization;
  bool _armed = false;
  bool _manuallySuspended = false;
  int attempts = 0;
  DateTime? nextAttemptAt;
  ManagedRecoveryError? error;
  bool busy = false;
  TermuxSetupStatus? status;
  String _token = '';
  String _operation = '';
  String _pendingOperation = '';
  bool _foreground = false;
  bool _disposed = false;
  bool _paused = false;
  int _epoch = 0;
  Timer? _timer;
  Future<void>? _inFlightCheck;

  bool get ownsInstallation => _owners[prefs] == profileID;
  bool get exhausted => attempts >= maxAttempts;
  bool get manuallySuspended => _manuallySuspended;
  bool get foreground => _foreground;
  bool get paused =>
      _paused ||
      _manuallySuspended ||
      !_foreground ||
      !_automationAllowed ||
      !ownsInstallation;
  ManagedRecoveryPhase get phase {
    if (!enabled) return ManagedRecoveryPhase.disabled;
    if (paused) return ManagedRecoveryPhase.paused;
    if (_pendingOperation.isNotEmpty) return ManagedRecoveryPhase.restarting;
    if (status?.isReady == true) return ManagedRecoveryPhase.monitoring;
    if (exhausted) return ManagedRecoveryPhase.exhausted;
    if (nextAttemptAt != null) return ManagedRecoveryPhase.waitingToRetry;
    return ManagedRecoveryPhase.waitingForServer;
  }

  Future<void> _migrateLegacyPreference() async {
    // Only a previously explicit opt-out with no policy record migrates. A
    // current policy, including a corrupt fail-closed record, always wins.
    if (_legacyEnabled == false &&
        prefs.getString(AutomationPolicyController.keyFor(profileID)) == null) {
      _legacyMigrationPending = true;
      try {
        await _policy.setBehavior(AutomationBehavior.restartPhoneServer, false);
        _legacyMigrationPending = false;
      } catch (_) {
        error = ManagedRecoveryError.settingsUnreadable;
      }
    }
    _notify();
    _schedule();
  }

  void _restore() {
    try {
      final raw = prefs.getString(preferenceKey(profileID));
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) throw const FormatException('Invalid recovery');
      final data = decoded is Map<String, dynamic>
          ? decoded
          : Map<String, dynamic>.from(decoded);
      _legacyEnabled = data['enabled'] is bool ? data['enabled'] as bool : null;
      final token = data['token'];
      final count = data['attempts'];
      final operation = data['operation'];
      final pending = data['pendingOperation'];
      if (token is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{0,64}$').hasMatch(token) ||
          count is! int ||
          count < 0 ||
          count > maxAttempts ||
          operation is! String ||
          pending is! String ||
          !RegExp(r'^[a-zA-Z0-9_-]{0,64}$').hasMatch(operation) ||
          !RegExp(r'^[a-zA-Z0-9_-]{0,64}$').hasMatch(pending)) {
        throw const FormatException('Invalid recovery settings');
      }
      _token = token;
      attempts = count;
      _operation = operation;
      _pendingOperation = pending;
      final unreported = data['unreportedOperation'];
      if (unreported is String &&
          RegExp(r'^[a-zA-Z0-9_-]{0,64}$').hasMatch(unreported)) {
        _unreportedOperation = unreported;
      }
      final confirmed = data['confirmedAtMs'];
      if (confirmed is int && confirmed > 0) {
        _confirmedAt = DateTime.fromMillisecondsSinceEpoch(confirmed);
      }
      final next = data['nextAttemptAtMs'];
      if (next != null && (next is! int || next < 0)) {
        throw const FormatException('Invalid recovery delay');
      }
      nextAttemptAt = next is int
          ? DateTime.fromMillisecondsSinceEpoch(next)
          : null;
      _paused = data['paused'] == true;
      _manuallySuspended = data['manuallySuspended'] == true;
    } catch (_) {
      _paused = true;
      error = ManagedRecoveryError.settingsUnreadable;
    }
  }

  int _sharedAttempts() {
    var spent = attempts;
    final ids = (_knownProfiles[prefs] ?? _instances[prefs]?.keys.toSet() ?? {})
        .difference(_retiredProfiles[prefs] ?? {});
    for (final id in ids) {
      final raw = prefs.getString(preferenceKey(id));
      if (raw == null) continue;
      final decoded = (() {
        try {
          return jsonDecode(raw);
        } catch (_) {
          return null;
        }
      })();
      final count = decoded is Map ? decoded['attempts'] : null;
      if (count is! int || count < 0 || count > maxAttempts) {
        throw StateError('Could not read recovery attempts');
      }
      if (count > spent) spent = count;
    }
    return spent;
  }

  static Future<void> _serializePreferenceWrite(
    SharedPreferences prefs,
    Future<void> Function() action,
  ) {
    final result = (_preferenceWrites[prefs] ?? Future<void>.value()).then(
      (_) => action(),
    );
    final settled = result.then<void>((_) {}, onError: (Object _) {});
    _preferenceWrites[prefs] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_preferenceWrites[prefs], settled)) {
          _preferenceWrites.remove(prefs);
        }
      }),
    );
    return result;
  }

  bool get _cannotSave =>
      _disposed || (_deletingProfiles[prefs]?.contains(profileID) ?? false);

  Future<void> _save() => _serializePreferenceWrite(prefs, () async {
    if (_cannotSave) return;
    attempts = _sharedAttempts();
    if (!await prefs.setString(
      preferenceKey(profileID),
      jsonEncode({
        'enabled': enabled,
        'token': _token,
        'attempts': attempts,
        'operation': _operation,
        'pendingOperation': _pendingOperation,
        'unreportedOperation': _unreportedOperation,
        'confirmedAtMs': _confirmedAt?.millisecondsSinceEpoch,
        'nextAttemptAtMs': nextAttemptAt?.millisecondsSinceEpoch,
        'paused': _paused,
        'manuallySuspended': _manuallySuspended,
      }),
    )) {
      throw StateError('Could not save recovery preference');
    }
    // Alias profiles share one installation. Mirror only the spent budget,
    // never their policy, so deleting/switching owners cannot reset retries.
    final ids = (_knownProfiles[prefs] ?? _instances[prefs]?.keys.toSet() ?? {})
        .difference(_retiredProfiles[prefs] ?? {});
    for (final id in ids.where((id) => id != profileID)) {
      if (_deletingProfiles[prefs]?.contains(id) ?? false) continue;
      final raw = prefs.getString(preferenceKey(id));
      final data = raw == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final previous = data['attempts'] as int? ?? 0;
      if (previous >= attempts) continue;
      data['attempts'] = attempts;
      data.putIfAbsent('token', () => _token);
      data.putIfAbsent('operation', () => '');
      data.putIfAbsent('pendingOperation', () => '');
      if (!await prefs.setString(preferenceKey(id), jsonEncode(data))) {
        throw StateError('Could not save recovery attempts');
      }
      final alias = _instances[prefs]?[id];
      if (alias != null) alias.attempts = attempts;
    }
  });

  Future<void> _disableForDeletion() async {
    await setEnabled(false);
    await _inFlightCheck;
  }

  Future<void> _suspend() async {
    if (_cannotSave) return;
    ++_epoch;
    _timer?.cancel();
    _manuallySuspended = true;
    _armed = false;
    _notify();
    final revoking = ownsInstallation ? _revokePermit() : Future<void>.value();
    try {
      await _save();
    } finally {
      await revoking;
    }
  }

  Future<void> _resumeAfterManualStart() async {
    if (_cannotSave || !_foreground) return;
    final epoch = ++_epoch;
    _timer?.cancel();
    try {
      final observed = await TermuxBridge.status();
      if (_cannotSave || epoch != _epoch || !_foreground) return;
      final expectedRuntime = _runtimes[prefs]?[profileID];
      if (!observed.isReady ||
          (expectedRuntime != null && observed.runtime != expectedRuntime) ||
          observed.switchPending ||
          observed.runner != 'proot' ||
          observed.port != TermuxBridge.managedServerPort ||
          observed.operationID.isEmpty) {
        return;
      }
      _operation = observed.operationID;
      _pendingOperation = '';
      _unreportedOperation = '';
      _confirmedAt = null;
      nextAttemptAt = null;
      _manuallySuspended = false;
      _paused = false;
      _armed = false;
      error = null;
      status = observed;
      await _save();
    } catch (_) {
      _paused = true;
      error = ManagedRecoveryError.uncertainResult;
    } finally {
      _notify();
      _schedule();
    }
  }

  /// The two settings surfaces edit the same persisted automation behavior.
  /// Re-enabling never replenishes the durable retry budget.
  Future<void> setEnabled(bool value) async {
    if (_cannotSave) return;
    if (!value) {
      _admissionClosed = true;
      ++_epoch;
      _timer?.cancel();
      _armed = false;
      _notify();
      // Revoke native admission immediately; a slow disk write cannot keep an
      // already dispatched recovery authorized while this stop waits its turn.
      final revoking = ownsInstallation
          ? _revokePermit()
          : Future<void>.value();
      try {
        await _initialization;
        await _policy.setBehavior(AutomationBehavior.restartPhoneServer, false);
        await _save();
      } finally {
        await revoking;
      }
      return;
    }
    await _initialization;
    await _policy.setBehavior(AutomationBehavior.restartPhoneServer, true);
    _admissionClosed = false;
    _notify();
    await checkNow();
    _schedule();
  }

  void _policyChanged() {
    ++_epoch;
    _timer?.cancel();
    if (!_automationAllowed) {
      _armed = false;
      if (_pendingOperation.isNotEmpty) {
        _paused = true;
        error = ManagedRecoveryError.uncertainResult;
      }
      if (!_admissionClosed && ownsInstallation) {
        unawaited(_revokeAfterPolicyChange());
      }
    } else {
      _admissionClosed = false;
    }
    _notify();
    _schedule();
  }

  Future<void> _revokePermit() {
    if (_token.isEmpty) return Future.value();
    final revoking = TermuxBridge.run(
      TermuxBridge.recoveryControlScript(_token, enable: false),
    ).then<void>((_) {});
    final settled = revoking.then<void>((_) {}, onError: (Object _) {});
    _revocations[prefs] = settled;
    unawaited(
      settled.then((_) {
        if (identical(_revocations[prefs], settled)) _revocations.remove(prefs);
      }),
    );
    return revoking;
  }

  Future<void> _revokeAfterPolicyChange() async {
    try {
      await _revokePermit();
      if (!_disposed && _token.isNotEmpty) await _save();
    } catch (_) {
      if (!_disposed) {
        _paused = true;
        error = ManagedRecoveryError.uncertainResult;
        _notify();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    ++_epoch;
    _timer?.cancel();
    if (!_foreground && _token.isNotEmpty && ownsInstallation) {
      _armed = false;
      if (_pendingOperation.isNotEmpty) {
        _paused = true;
        error = ManagedRecoveryError.uncertainResult;
      }
      final token = _token;
      final epoch = _epoch;
      unawaited(_revokeBackgroundRecovery(token, epoch));
    }
    _notify();
    _schedule();
  }

  Future<void> _revokeBackgroundRecovery(String token, int epoch) async {
    try {
      await _revokePermit();
    } catch (_) {
      if (!_disposed) {
        _paused = true;
        error = ManagedRecoveryError.uncertainResult;
      }
    }
    if (_disposed || _token != token || _epoch != epoch || !_paused) return;
    try {
      await _save();
    } catch (_) {}
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed ||
        !enabled ||
        !_automationAllowed ||
        !_foreground ||
        _paused ||
        _manuallySuspended ||
        !ownsInstallation ||
        busy) {
      return;
    }
    _timer = Timer(const Duration(seconds: 5), checkNow);
  }

  /// A manual check resumes a transient probe error without resetting retries.
  Future<void> retryCheck() async {
    _paused = false;
    error = null;
    await _save();
    await checkNow();
  }

  Future<void> checkNow() {
    if (busy) return _inFlightCheck ?? Future.value();
    final checking = _checkNow();
    _inFlightCheck = checking;
    return checking.whenComplete(() {
      if (identical(_inFlightCheck, checking)) _inFlightCheck = null;
    });
  }

  Future<void> _checkNow() async {
    if (_disposed ||
        !enabled ||
        !_automationAllowed ||
        !_foreground ||
        _paused ||
        _manuallySuspended ||
        !ownsInstallation ||
        busy) {
      return;
    }
    busy = true;
    final epoch = _epoch;
    bool current() =>
        !_disposed &&
        ownsInstallation &&
        enabled &&
        _automationAllowed &&
        _foreground &&
        epoch == _epoch;
    try {
      await _revocations[prefs];
      if (!current()) return;
      final snapshot = await TermuxBridge.status();
      if (!current()) return;
      status = snapshot;
      final expectedRuntime = _runtimes[prefs]?[profileID];
      if (expectedRuntime != null && snapshot.runtime != expectedRuntime) {
        _paused = true;
        error = ManagedRecoveryError.ownershipChanged;
        await _save();
        return;
      }
      if (_operation.isEmpty) {
        // A missing/not-yet-installed/stopped/uncertain server is not a crash.
        if ((!snapshot.isReady && !snapshot.canRecover) ||
            snapshot.runner != 'proot' ||
            snapshot.port != TermuxBridge.managedServerPort ||
            snapshot.operationID.isEmpty) {
          return;
        }
        _operation = snapshot.operationID;
      }
      if (!_armed &&
          _pendingOperation.isEmpty &&
          snapshot.operationID == _operation &&
          (snapshot.isReady || snapshot.canRecover) &&
          !exhausted) {
        if (_token.isEmpty) {
          _token = List.generate(
            16,
            (_) =>
                Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
          ).join();
        }
        await _save();
        if (!current()) return;
        await TermuxBridge.run(
          TermuxBridge.recoveryControlScript(_token, enable: true),
        );
        if (!current()) {
          await _revokePermit();
          return;
        }
        _armed = true;
      }
      if (_pendingOperation.isNotEmpty &&
          snapshot.operationID == _pendingOperation) {
        _operation = _pendingOperation;
        _pendingOperation = '';
        if (snapshot.canRecover) _unreportedOperation = '';
        await _save();
        if (!current()) return;
      }
      if (snapshot.operationID != _operation || snapshot.phase == 'stopped') {
        _paused = true;
        error = ManagedRecoveryError.ownershipChanged;
        await _save();
        return;
      }
      if (_unreportedOperation.isNotEmpty &&
          snapshot.isReady &&
          snapshot.operationID == _unreportedOperation) {
        _confirmedAt ??= _now();
        await _save();
        if (!current()) return;
        final recorded = await _onRestart?.call(
          profileId: profileID,
          eventId: 'managed-restart:$_unreportedOperation',
          at: _confirmedAt!,
        );
        if (!current()) return;
        if (recorded == true) {
          _unreportedOperation = '';
          _confirmedAt = null;
          await _save();
        }
      }
      if (snapshot.isReady && nextAttemptAt != null) {
        nextAttemptAt = null;
        await _save();
        return;
      }
      if (!snapshot.canRecover || exhausted || !_armed) return;
      final now = _now();
      if (nextAttemptAt == null) {
        nextAttemptAt = now.add(backoff[attempts]);
        await _save();
        return;
      }
      if (now.isBefore(nextAttemptAt!)) return;
      // Reserve and durably consume the attempt before dispatch. App death
      // cannot grant a fresh budget for an operation with an unknown outcome.
      final savedAttempts = attempts;
      final savedNextAttemptAt = nextAttemptAt;
      final savedPendingOperation = _pendingOperation;
      final savedUnreportedOperation = _unreportedOperation;
      final savedConfirmedAt = _confirmedAt;
      attempts++;
      final operationPrefix = _token.length > 16
          ? _token.substring(0, 16)
          : _token;
      _pendingOperation = '$operationPrefix-$attempts';
      _unreportedOperation = _pendingOperation;
      _confirmedAt = null;
      nextAttemptAt = attempts < maxAttempts
          ? now.add(backoff[attempts])
          : null;
      try {
        await _save();
      } catch (_) {
        // No native command was dispatched: do not claim an attempt that the
        // durable record could not acknowledge. Keep recovery paused until a
        // later explicit check can persist a trustworthy state.
        if (!current()) return;
        attempts = savedAttempts;
        nextAttemptAt = savedNextAttemptAt;
        _pendingOperation = savedPendingOperation;
        _unreportedOperation = savedUnreportedOperation;
        _confirmedAt = savedConfirmedAt;
        _paused = true;
        error = ManagedRecoveryError.settingsUnreadable;
        try {
          await _save();
        } catch (_) {}
        return;
      }
      if (!current()) return;
      await TermuxBridge.run(
        TermuxBridge.restartScript(
          operationID: _pendingOperation,
          recoveryToken: _token,
          expectedOperationID: _operation,
        ),
        timeout: const Duration(seconds: 90),
      );
    } catch (_) {
      if (current()) {
        // A definite startup failure can use the remaining bounded budget.
        // Unknown callback outcomes pause instead of overlapping operations.
        if (_pendingOperation.isNotEmpty) {
          try {
            final observed = await TermuxBridge.status();
            if (!current()) return;
            if (observed.operationID == _pendingOperation &&
                observed.canRecover) {
              _operation = _pendingOperation;
              _pendingOperation = '';
              _unreportedOperation = '';
              status = observed;
              await _save();
              return;
            }
          } catch (_) {}
        }
        if (!current()) return;
        // Unknown callback outcomes require an explicit check. Never blindly
        // issue another restart while a previous command could still run.
        _paused = true;
        error = ManagedRecoveryError.uncertainResult;
        try {
          await _save();
        } catch (_) {}
      }
    } finally {
      busy = false;
      _notify();
      _schedule();
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _timer?.cancel();
    _policy.removeListener(_policyChanged);
    if (_pendingOperation.isNotEmpty && ownsInstallation) {
      unawaited(_revokeAfterPolicyChange());
    }
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
