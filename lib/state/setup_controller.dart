import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../domain/setup_assistant.dart';
import '../ui/kit/kit_redact.dart';
import 'setup_audit_store.dart';

/// Profile-and-location-bound review coordinator. Recreate on location change;
/// dispose before deleting a profile. Nothing queues writes while offline.
class SetupController {
  SetupController({
    required this.gateway,
    required this.prefs,
    required this.profileId,
    required this.locationId,
    bool Function()? isCurrent,
  }) : _isCurrent = isCurrent ?? (() => true),
       _auditStore = SetupAuditStore.forProfile(prefs, profileId) {
    if (profileId.isEmpty || locationId.isEmpty) {
      throw ArgumentError('Setup requires a profile and location.');
    }
  }
  final SetupConfigGateway gateway;
  final SharedPreferences prefs;
  final String profileId;
  final String locationId;
  final bool Function() _isCurrent;
  final SetupAuditStore _auditStore;
  String get auditKey => 'oc.setupAudit.$profileId';
  final _events = StreamController<SetupSnapshot>.broadcast();
  Stream<SetupSnapshot> get changes => _events.stream;
  SetupSnapshot get snapshot => _snapshot;
  SetupSupport get support {
    final advertised = gateway.support;
    if (!advertised.writeConfig || _transactional != null) return advertised;
    return SetupSupport(
      readConfig: advertised.readConfig,
      mcpInventory: advertised.mcpInventory,
      assistant: advertised.assistant,
      reason:
          'This server has no verified atomic configuration restore endpoint. Apply and Undo are unavailable.',
    );
  }

  SetupSnapshot _snapshot = const SetupSnapshot();
  Map<String, Object?>? _base;
  SetupConfigRevision? _baseRevision;
  SetupConfigCommit? _undo;
  List<SetupEdit> _edits = const [];

  bool _online = true, _busy = false, _disposed = false;
  static final _random = Random.secure();
  String _id() => List.generate(
    24,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  SetupTransactionalConfigGateway? get _transactional =>
      gateway is SetupTransactionalConfigGateway
      ? gateway as SetupTransactionalConfigGateway
      : null;
  bool get _writable => support.writeConfig && _transactional != null;
  String get _writeReason => !support.writeConfig
      ? support.reason
      : 'This server has no verified atomic configuration restore endpoint. Apply and Undo are unavailable.';
  Completer<void>? _finished;

  void setOnline(bool online) {
    _online = online;
    if (!online) {
      _emit(
        SetupSnapshot(
          phase: SetupPhase.offline,
          config: _snapshot.config,
          servers: _snapshot.servers,
          reason: 'Reconnect to your server to refresh or apply changes.',
        ),
      );
    }
  }

  Future<void> refresh() => _run(() async {
    _requireOnline();
    if (!support.readConfig) {
      throw SetupFailure(SetupFailureCode.unsupported, support.reason);
    }
    _emit(const SetupSnapshot(phase: SetupPhase.loading));
    final revision = await _transactional?.readSnapshot();
    _requireOnline();
    if (revision != null) {
      KitRedact.registerCredentialValues(revision.config);
      _validateRevision(revision);
    }
    final config = revision?.config ?? await gateway.readConfig();
    _requireOnline();
    final servers = support.mcpInventory
        ? await gateway.listMcpServers()
        : <SetupMcpStatus>[];
    _requireOnline();
    KitRedact.registerCredentialValues(config);
    _base = _clone(config);
    _baseRevision = revision;
    _edits = const [];
    _emit(
      SetupSnapshot(
        phase: config.isEmpty && servers.isEmpty
            ? SetupPhase.empty
            : SetupPhase.ready,
        config: setupRedact(config) as Map<String, Object?>,
        servers: List.unmodifiable(
          servers.map(
            (s) => SetupMcpStatus(
              name: KitRedact.text(s.name),
              status: _status(s.status),
            ),
          ),
        ),
        canUndo: _undo != null,
      ),
    );
  });

  /// Returns a reviewable diff. Validation is local and cannot prove that a
  /// server accepts a schema or that a package can run on its host.
  Future<SetupProposal> propose(List<SetupEdit> edits) => _run(() async {
    _requireCurrent();
    final base = _base;
    if (base == null) {
      throw const SetupFailure(
        SetupFailureCode.invalid,
        'Read the current configuration first.',
      );
    }
    if (base.containsKey('sources')) {
      throw const SetupFailure(
        SetupFailureCode.unsupported,
        'This server returns layered sources. Effective-config diffs are unavailable.',
      );
    }
    final errors = validate(edits);
    if (errors.isNotEmpty) {
      throw SetupFailure(SetupFailureCode.invalid, errors.first);
    }
    _edits = edits
        .map(
          (e) => SetupEdit(
            path: List.unmodifiable(e.path),
            value: jsonDecode(jsonEncode(e.value)),
            remove: e.remove,
          ),
        )
        .toList(growable: false);
    final unavailable = _mutationReason(base, _edits);
    final proposal = SetupProposal(
      id: _id(),
      changes: _edits
          .map(
            (e) => SetupDiff(
              path: e.path,
              before: setupRedact(_at(base, e.path), e.path.last),
              after: setupRedact(e.value, e.path.last),
              remove: e.remove,
              beforePresent: _has(base, e.path),
              afterPresent: !e.remove,
            ),
          )
          .toList(),
      canApply: _writable && unavailable == null && _online && _isCurrent(),
      reason: !_writable
          ? _writeReason
          : unavailable ??
                (!_online ? 'Reconnect to your server before applying.' : null),
    );
    await _audit(proposal.id, 'proposed');
    _requireCurrent();
    _emit(
      SetupSnapshot(
        phase: _online ? SetupPhase.ready : SetupPhase.offline,
        config: _snapshot.config,
        servers: _snapshot.servers,
        proposal: proposal,
        canUndo: _undo != null,
      ),
    );
    return proposal;
  });

  String? _mutationReason(Map<String, Object?> base, List<SetupEdit> edits) {
    for (final edit in edits) {
      Object? ancestor = base;
      for (final segment in edit.path.take(edit.path.length - 1)) {
        if (ancestor is! Map || !ancestor.containsKey(segment)) {
          break;
        }
        ancestor = ancestor[segment];
        if (ancestor is! Map) {
          return 'This change would replace a containing setting. Review that setting separately before continuing.';
        }
      }
      final root = edit.path.first;
      if (const {'model', 'small_model', 'default_agent'}.contains(root) &&
          !edit.remove &&
          edit.path.length == 1) {
        continue;
      }
      if (root == 'permission' && !edit.remove && edit.path.length == 2) {
        continue;
      }
      if (root == 'mcp' && edit.path.length == 2) {
        final previous = _at(base, edit.path);
        final mcp = base['mcp'];
        final exists =
            (mcp is Map) && mcp.containsKey(edit.path.last);
        if (exists &&
            (previous is! Map ||
                previous['type'] != 'remote' ||
                previous['enabled'] != false)) {
          return 'Only disabled remote MCP definitions can be changed here. Runtime connections and sign-in state are not restored.';
        }
        if (edit.remove) {
          if (exists) {
            continue;
          }
          return 'The MCP definition is absent. Refresh and review a current definition.';
        }
        if (edit.value is Map &&
            (edit.value as Map)['type'] == 'remote' &&
            (edit.value as Map)['enabled'] == false) {
          continue;
        }
        return 'Local MCP commands require a separate command review. They cannot be applied here.';
      }
      return 'This setting has no reviewed reversible setup action. Use the existing server configuration or secure sign-in flow.';
    }
    return null;
  }

  List<String> validate(List<SetupEdit> edits) {
    if (edits.isEmpty || edits.length > 32) {
      return ['Choose between one and 32 changes.'];
    }
    const roots = {
      'model',
      'small_model',
      'default_agent',
      'provider',
      'providers',
      'agent',
      'agents',
      'permission',
      'permissions',
      'command',
      'commands',
      'mcp',
    };
    for (final edit in edits) {
      if (edit.path.isEmpty ||
          !roots.contains(edit.path.first) ||
          edit.path.any(
            (s) => !RegExp(r'^[a-zA-Z0-9_./:@*-]{1,160}$').hasMatch(s),
          )) {
        return ['Choose a supported configuration field.'];
      }
      if (!edit.remove) {
        final root = edit.path.first;
        if (const {'model', 'small_model', 'default_agent'}.contains(root) &&
            (edit.path.length != 1 ||
                edit.value is! String ||
                (edit.value as String).trim().isEmpty)) {
          return ['Choose a valid model or agent identifier.'];
        }
        if (root == 'permission' &&
            (edit.path.length != 2 ||
                !const {'allow', 'ask', 'deny'}.contains(edit.value))) {
          return ['Choose an allow, ask, or deny permission rule.'];
        }
        if (root == 'mcp' && edit.path.length == 2) {
          final value = edit.value;
          if (value is! Map ||
              !const {'local', 'remote'}.contains(value['type']) ||
              value['enabled'] != false) {
            return [
              'A new MCP proposal must specify its type and start disabled.',
            ];
          }
          if (value['type'] == 'local' &&
              (value['command'] is! List ||
                  (value['command'] as List).isEmpty ||
                  (value['command'] as List).any(
                    (v) => v is! String || v.trim().isEmpty,
                  ))) {
            return ['Choose a valid command for the local MCP server.'];
          }
          if (value['type'] == 'remote') {
            final uri = value['url'] is String
                ? Uri.tryParse(value['url'] as String)
                : null;
            if (uri == null ||
                uri.host.isEmpty ||
                uri.userInfo.isNotEmpty ||
                uri.hasQuery ||
                uri.hasFragment ||
                !(uri.scheme == 'https' ||
                    (uri.scheme == 'http' &&
                        const {
                          'localhost',
                          '127.0.0.1',
                          '::1',
                        }.contains(uri.host)))) {
              return [
                'Choose an HTTPS or local loopback MCP URL without credentials.',
              ];
            }
          }
        }
      }
      // Raw credentials must use the existing sign-in/secret entry flows.
      final wrapped = <String, Object?>{};
      _put(wrapped, edit.path, edit.value);
      final raw = jsonEncode(wrapped);
      if (raw.length > 32768 ||
          KitRedact.containsSecret(raw) ||
          raw.contains(KitRedact.mask)) {
        return [
          'Use the existing sign-in or secret entry flow for credentials.',
        ];
      }
      if (RegExp(
            r'key|token|secret|password|credential|environment|headers|options',
            caseSensitive: false,
          ).hasMatch(edit.path.join('.')) ||
          _sensitiveMap(edit.value)) {
        return [
          'Use the existing sign-in or secret entry flow for credentials.',
        ];
      }
      if (!edit.remove && edit.value == null) {
        return ['A configuration value is required.'];
      }
    }
    for (var i = 0; i < edits.length; i++) {
      for (var j = i + 1; j < edits.length; j++) {
        final a = edits[i].path, b = edits[j].path;
        if (_prefix(a, b) || _prefix(b, a)) {
          return ['Review overlapping fields as separate proposals.'];
        }
      }
    }
    return const [];
  }

  /// Only an atomic source transaction can make a reviewed proposal writable.
  Future<void> apply(
    String proposalId, {
    required bool confirmed,
  }) => _run(() async {
    _requireOnline();
    if (!_writable) {
      throw SetupFailure(SetupFailureCode.unsupported, _writeReason);
    }
    final proposal = _snapshot.proposal;
    if (!confirmed ||
        proposal == null ||
        proposal.id != proposalId ||
        !proposal.canApply) {
      throw const SetupFailure(
        SetupFailureCode.invalid,
        'Review and confirm the current proposal first.',
      );
    }
    _operationPhase(SetupPhase.applying);
    final current = await _transactional!.readSnapshot();
    KitRedact.registerCredentialValues(current.config);
    _requireOnline();
    if (!_sameRevision(current, _baseRevision)) {
      throw const SetupFailure(
        SetupFailureCode.conflict,
        'Configuration changed on the server. Refresh and review a new proposal.',
      );
    }
    final expected = _clone(current.config);
    for (final edit in _edits) {
      if (edit.remove) {
        _remove(expected, edit.path);
      } else {
        _put(expected, edit.path, edit.value);
      }
    }
    final edits = _edits;
    final result = await _transact(
      proposal.id,
      'apply',
      current,
      expected,
      () => _transactional!.commit(
        expected: current,
        edits: edits,
        operationId: proposal.id,
      ),
    );
    _undo = result;
    _requireOnline();
    _publishReady();
  });

  Future<void> undo({required bool confirmed}) => _run(() async {
    _requireOnline();
    if (!_writable) {
      throw SetupFailure(SetupFailureCode.unsupported, _writeReason);
    }
    final previous = _undo;
    if (!confirmed || previous == null) {
      throw const SetupFailure(
        SetupFailureCode.invalid,
        'There is no confirmed change to undo in this setup session.',
      );
    }
    _operationPhase(SetupPhase.undoing);
    final current = await _transactional!.readSnapshot();
    KitRedact.registerCredentialValues(current.config);
    _requireOnline();
    if (!_sameRevision(current, previous.after)) {
      throw const SetupFailure(
        SetupFailureCode.conflict,
        'Configuration changed after Apply. Refresh before making another change.',
      );
    }
    final id = _id();
    await _transact(
      id,
      'undo',
      current,
      previous.before.config,
      () => _transactional!.restore(commit: previous, operationId: id),
    );
    _undo = null;
    _requireOnline();
    _publishReady();
  });

  Future<SetupConfigCommit> _transact(
    String id,
    String operation,
    SetupConfigRevision current,
    Map<String, Object?> expected,
    Future<SetupConfigCommit> Function() send,
  ) async {
    await _audit(id, 'pending', operation: operation);
    _requireOnline();
    var acknowledged = false;
    try {
      final result = await send();
      acknowledged = true;
      KitRedact.registerCredentialValues(result.before.config);
      KitRedact.registerCredentialValues(result.after.config);
      // After dispatch reconcile the original captured host even if its screen
      // closes. Never send another mutation or publish ready to a stale owner.
      await _audit(id, 'accepted', operation: operation);
      _validateRevision(result.before);
      _validateRevision(result.after);
      if (!_sameRevision(result.before, current) ||
          result.after.targetId != current.targetId ||
          result.after.revision == current.revision ||
          result.undoHandle.isEmpty ||
          !_same(result.after.config, expected)) {
        throw const SetupFailure(
          SetupFailureCode.uncertain,
          'The configuration change could not be verified.',
        );
      }
      if (_canPublish) _operationPhase(SetupPhase.verifying);
      final actual = await _transactional!.readSnapshot();
      KitRedact.registerCredentialValues(actual.config);
      if (!_sameRevision(actual, result.after)) {
        throw const SetupFailure(
          SetupFailureCode.uncertain,
          'The configuration change could not be verified.',
        );
      }
      await _audit(id, 'verified', operation: operation);
      _base = _clone(actual.config);
      _baseRevision = actual;
      return result;
    } catch (error) {
      _base = null;
      _baseRevision = null;
      _undo = null;
      final rejected =
          !acknowledged &&
          error is SetupFailure &&
          error.code == SetupFailureCode.conflict;
      try {
        await _audit(
          id,
          rejected ? 'rejected' : 'uncertain',
          operation: operation,
        );
      } catch (_) {
        /* durable pending remains */
      }
      if (rejected) rethrow;
      throw const SetupFailure(
        SetupFailureCode.uncertain,
        'The change outcome is unknown. Refresh before trying again.',
      );
    } finally {
      _edits = const [];
    }
  }

  bool get _canPublish =>
      !_disposed && _online && _isCurrent() && _auditStore.isAvailable;
  void _operationPhase(SetupPhase phase) => _emit(
    SetupSnapshot(
      phase: phase,
      config: _snapshot.config,
      servers: _snapshot.servers,
    ),
  );
  void _publishReady() => _emit(
    SetupSnapshot(
      phase: SetupPhase.ready,
      config: setupRedact(_base) as Map<String, Object?>,
      servers: _snapshot.servers,
      canUndo: _undo != null,
    ),
  );
  void _validateRevision(SetupConfigRevision revision) {
    if (revision.targetId.isEmpty || revision.revision.isEmpty) {
      throw const SetupFailure(
        SetupFailureCode.invalid,
        'The server returned an unsupported configuration snapshot.',
      );
    }
  }

  static bool _sameRevision(SetupConfigRevision a, SetupConfigRevision? b) =>
      b != null &&
      a.targetId == b.targetId &&
      a.revision == b.revision &&
      _same(a.config, b.config);

  /// Only bounded metadata is stored; never snapshots or restore handles.
  List<Map<String, Object?>> get audit => _auditStore.records;
  Future<void> _audit(String id, String action, {String? operation}) =>
      _auditStore.append(id, action, operation: operation);

  Future<T> _run<T>(Future<T> Function() action) async {
    if (_disposed || _busy) {
      throw const SetupFailure(
        SetupFailureCode.busy,
        'Setup is busy or closed.',
      );
    }
    _busy = true;
    _finished = Completer<void>();
    try {
      return await action();
    } catch (error) {
      final failure = error is SetupFailure
          ? error
          : const SetupFailure(
              SetupFailureCode.transport,
              'Could not contact the setup service.',
            );
      final phase = switch (failure.code) {
        SetupFailureCode.offline => SetupPhase.offline,
        SetupFailureCode.unsupported => SetupPhase.unsupported,
        SetupFailureCode.needsSignIn => SetupPhase.needsSignIn,
        SetupFailureCode.uncertain => SetupPhase.uncertain,
        _ => SetupPhase.error,
      };
      _emit(
        SetupSnapshot(
          phase: phase,
          config: _snapshot.config,
          servers: _snapshot.servers,
          reason: KitRedact.text(failure.message),
        ),
      );
      throw failure;
    } finally {
      _busy = false;
      _finished?.complete();
    }
  }

  void _requireCurrent() {
    if (_disposed || !_isCurrent()) {
      throw const SetupFailure(
        SetupFailureCode.offline,
        'Setup is closed or the selected server changed.',
      );
    }
    if (!_auditStore.isAvailable) {
      throw const SetupFailure(
        SetupFailureCode.storage,
        'Setup history is unavailable. Refresh before trying again.',
      );
    }
  }

  void _requireOnline() {
    _requireCurrent();
    if (!_online) {
      throw const SetupFailure(
        SetupFailureCode.offline,
        'Reconnect to your server before continuing.',
      );
    }
  }

  void _emit(SetupSnapshot value) {
    if (!_disposed && _isCurrent()) {
      _snapshot = value;
      _events.add(value);
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _finished?.future;
    _base = null;
    _baseRevision = null;
    _edits = const [];
    _undo = null;
    _snapshot = const SetupSnapshot();
    await _events.close();
  }

  static bool _same(Object? a, Object? b) {
    if (a is Map && b is Map) {
      return a.length == b.length &&
          a.keys.every((key) => b.containsKey(key) && _same(a[key], b[key]));
    }
    if (a is List && b is List) {
      return a.length == b.length &&
          Iterable<int>.generate(a.length).every((i) => _same(a[i], b[i]));
    }
    return a == b;
  }

  static Map<String, Object?> _clone(Map<String, Object?> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, Object?>();
  static String _status(String status) =>
      const {
        'connected',
        'pending',
        'disabled',
        'failed',
        'needs_auth',
        'needs_client_registration',
      }.contains(status)
      ? status
      : 'unknown';
  static bool _prefix(List<String> a, List<String> b) =>
      a.length <= b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
  static bool _sensitiveMap(Object? value) {
    if (value is Map) {
      return value.entries.any(
        (e) =>
            RegExp(
              r'key|token|secret|password|credential|environment|headers|options',
              caseSensitive: false,
            ).hasMatch(e.key.toString()) ||
            _sensitiveMap(e.value),
      );
    }
    if (value is List) return value.any(_sensitiveMap);
    return false;
  }

  static Object? _at(Map<String, Object?> map, List<String> path) {
    Object? at = map;
    for (final part in path) {
      if (at is! Map) return null;
      at = at[part];
    }
    return at;
  }

  static bool _has(Map<String, Object?> map, List<String> path) {
    Object? at = map;
    for (final key in path) {
      if (at is! Map || !at.containsKey(key)) return false;
      at = at[key];
    }
    return true;
  }

  static void _remove(Map<String, Object?> map, List<String> path) {
    Object? at = map;
    for (final part in path.take(path.length - 1)) {
      if (at is! Map) return;
      at = at[part];
    }
    if (at is Map) at.remove(path.last);
  }

  static void _put(Map<String, Object?> map, List<String> path, Object? value) {
    var at = map;
    for (final part in path.take(path.length - 1)) {
      final child = at[part];
      at[part] = child is Map
          ? Map<String, Object?>.from(child)
          : <String, Object?>{};
      at = at[part] as Map<String, Object?>;
    }
    at[path.last] = value;
  }
}
