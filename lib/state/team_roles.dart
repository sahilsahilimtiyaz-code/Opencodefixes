/// AI Team roles (personas): named instruction sets a task is given to —
/// Product, Frontend, Backend, Tester, or the person's own. On the phone
/// one worker runs at a time and "puts on" the task's role: the role's
/// instructions travel in the task's description and its model (if any)
/// is applied just before the task is handed over. No extra processes.
///
/// CONTRACT (frozen 2026-09-29 for the roles slices): names, fields and
/// signatures below are shared by the state slice (which implements the
/// bodies) and the UI slice (which only calls them). Do not rename.
library;

import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../orchestration/models/run.dart';
import 'orchestration.dart';
import 'team_model.dart';

/// Ids of the roles every team starts with. Their display names and
/// one-line purposes are UI copy (l10n, keyed by id); their [TeamRole
/// .instructions] are English prompt text sent to the model.
abstract final class TeamRoleIds {
  static const general = 'general';
  static const product = 'product';
  static const frontend = 'frontend';
  static const backend = 'backend';
  static const tester = 'tester';

  static const builtIn = [general, product, frontend, backend, tester];
}

@immutable
class TeamRole {
  const TeamRole({
    required this.id,
    required this.name,
    required this.purpose,
    required this.instructions,
    this.model,
    this.builtIn = false,
  });

  /// Stable id: a [TeamRoleIds] value, or `custom-<random>` for the
  /// person's own roles.
  final String id;

  /// Shown name. For a built-in role the stored name is empty until the
  /// person renames it; the UI then shows the l10n name for [id].
  final String name;

  /// One line: what this role is for. Shown under the name and used as the
  /// hint when the app suggests a role for a task. Empty for an unedited
  /// built-in (UI shows the l10n purpose).
  final String purpose;

  /// Prompt text put in front of the task for the worker. Empty for
  /// [TeamRoleIds.general] (the task goes as written).
  final String instructions;

  /// `provider/model` (see `isValidTeamModel`), or null: the team's model.
  final String? model;

  final bool builtIn;

  TeamRole copyWith({
    String? name,
    String? purpose,
    String? instructions,
    String? Function()? model,
  }) => TeamRole(
    id: id,
    name: name ?? this.name,
    purpose: purpose ?? this.purpose,
    instructions: instructions ?? this.instructions,
    model: model == null ? this.model : model(),
    builtIn: builtIn,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'purpose': purpose,
    'instructions': instructions,
    if (model != null) 'model': model,
    'builtIn': builtIn,
  };

  /// Null for anything that is not a well-formed role (corrupt storage).
  static TeamRole? fromJson(Object? json) {
    if (json is! Map) return null;
    final id = json['id'];
    if (id is! String || id.isEmpty) return null;
    String text(String key) {
      final v = json[key];
      return v is String ? v : '';
    }

    final model = json['model'];
    return TeamRole(
      id: id,
      name: text('name'),
      purpose: text('purpose'),
      instructions: text('instructions'),
      model: model is String && isValidTeamModel(model) ? model : null,
      builtIn: TeamRoleIds.builtIn.contains(id),
    );
  }
}

/// The roles every team starts with, as they shipped. Names and purposes
/// are empty: the UI shows the l10n text for the id until a rename.
abstract final class TeamRoles {
  static const _followRepo =
      "Follow the repository's own AGENTS.md / CLAUDE.md and existing "
      'conventions.';

  static const _instructions = <String, String>{
    TeamRoleIds.general: '',
    TeamRoleIds.product:
        'You are acting as the product owner for this task.\n'
        '- Clarify the goal and who it is for; note open questions instead '
        'of guessing.\n'
        '- Write a short spec with clear acceptance criteria as a file in '
        'the repository (for example under docs/).\n'
        '- Do not write application code unless the change is trivial.\n'
        '- $_followRepo',
    TeamRoleIds.frontend:
        'You are acting as the frontend engineer for this task.\n'
        '- Build the user interface: layout, states (loading, empty, '
        'error), and accessibility (labels, contrast, touch targets).\n'
        "- Reuse the project's existing design system and components "
        'rather than making new ones.\n'
        "- Run the project's lint and tests for the code you touch before "
        'finishing.\n'
        '- $_followRepo',
    TeamRoleIds.backend:
        'You are acting as the backend engineer for this task.\n'
        '- Work on APIs, data models, storage and error handling; make '
        'failures explicit and recoverable.\n'
        '- Validate input, and never log or expose secrets or personal '
        'data.\n'
        '- Add or update tests for the behavior you change and run them.\n'
        '- $_followRepo',
    TeamRoleIds.tester:
        'You are acting as the tester for this task.\n'
        '- Write and run tests that check the behavior described; cover '
        'the normal path and the likely failures.\n'
        '- Report each failure with steps to reproduce, what you expected '
        'and what happened.\n'
        '- Change only test code unless the task explicitly asks you to '
        'fix the product code.\n'
        '- $_followRepo',
  };

  /// The built-in roles as shipped, in [TeamRoleIds.builtIn] order.
  static List<TeamRole> get defaults => [
    for (final id in TeamRoleIds.builtIn)
      TeamRole(
        id: id,
        name: '',
        purpose: '',
        instructions: _instructions[id]!,
        builtIn: true,
      ),
  ];

  static TeamRole defaultFor(String id) => defaults.firstWhere(
    (r) => r.id == id,
    orElse: () => throw StateError('Unknown team role'),
  );

  /// Words that point at a built-in role (lowercase, matched as whole
  /// words or word prefixes).
  static const vocabulary = <String, List<String>>{
    TeamRoleIds.product: [
      'spec',
      'requirements',
      'requirement',
      'scope',
      'user story',
      'stories',
      'acceptance',
      'roadmap',
      'plan',
      'prd',
      'prioritize',
    ],
    TeamRoleIds.frontend: [
      'ui',
      'screen',
      'button',
      'layout',
      'design',
      'css',
      'style',
      'theme',
      'page',
      'widget',
      'animation',
      'accessibility',
      'responsive',
      'icon',
      'dark mode',
    ],
    TeamRoleIds.backend: [
      'api',
      'endpoint',
      'database',
      'server',
      'sql',
      'migration',
      'auth',
      'token',
      'cache',
      'queue',
      'schema',
      'storage',
      'security',
    ],
    TeamRoleIds.tester: [
      'test',
      'tests',
      'testing',
      'bug',
      'repro',
      'regression',
      'coverage',
      'flaky',
      'verify',
      'qa',
    ],
  };
}

/// The roles of one profile's team and which role each task was given.
///
/// Storage (swept with the profile by the scoped-key deletion):
/// - `oc.teamRoles.<profileId>`: JSON list of [TeamRole] (built-ins stored
///   only once edited; missing built-ins come from [TeamRoles.defaults]).
/// - `oc.teamTaskRoles.<profileId>`: JSON map work/run id -> role id.
class TeamRolesController extends ChangeNotifier {
  TeamRolesController(this.prefs, this.profileId) {
    _roles = _readRoles();
    _taskRoles = _readTaskRoles();
  }

  final SharedPreferences prefs;
  final String profileId;

  static String rolesKey(String profileId) => 'oc.teamRoles.$profileId';
  static String taskRolesKey(String profileId) => 'oc.teamTaskRoles.$profileId';

  /// Stored roles: edited built-ins and the person's own, in stored order.
  late List<TeamRole> _roles;
  late Map<String, String> _taskRoles;

  List<TeamRole> _readRoles() {
    try {
      final raw = prefs.getString(rolesKey(profileId));
      if (raw == null) return [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final seen = <String>{};
      return [
        for (final item in decoded)
          if (TeamRole.fromJson(item) case final role? when seen.add(role.id))
            role,
      ];
    } catch (_) {
      return [];
    }
  }

  Map<String, String> _readTaskRoles() {
    try {
      final raw = prefs.getString(taskRolesKey(profileId));
      if (raw == null) return {};
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return {};
      return {
        for (final e in decoded.entries)
          if (e.key is String && e.value is String)
            e.key as String: e.value as String,
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveRoles() async {
    notifyListeners();
    try {
      await prefs.setString(
        rolesKey(profileId),
        jsonEncode([for (final r in _roles) r.toJson()]),
      );
    } catch (_) {
      // Kept in memory for this session; the next save tries again.
    }
  }

  /// Built-ins first in [TeamRoleIds.builtIn] order, then the person's own
  /// in creation order.
  List<TeamRole> get roles {
    final stored = {for (final r in _roles) r.id: r};
    return [
      for (final d in TeamRoles.defaults) stored[d.id] ?? d,
      for (final r in _roles)
        if (!r.builtIn) r,
    ];
  }

  TeamRole? byId(String id) {
    for (final r in roles) {
      if (r.id == id) return r;
    }
    return null;
  }

  static final _random = Random.secure();

  String _newId() {
    while (true) {
      final id =
          'custom-${_random.nextInt(1 << 32).toRadixString(36)}'
          '${_random.nextInt(1 << 32).toRadixString(36)}';
      if (_roles.every((r) => r.id != id)) return id;
    }
  }

  /// Adds a role of the person's own; returns it with its new id.
  Future<TeamRole> add({
    required String name,
    required String purpose,
    required String instructions,
    String? model,
  }) async {
    final role = TeamRole(
      id: _newId(),
      name: name.trim(),
      purpose: purpose.trim(),
      instructions: instructions.trim(),
      model: model != null && isValidTeamModel(model) ? model : null,
    );
    _roles = [..._roles, role];
    await _saveRoles();
    return role;
  }

  /// Saves an edited role (built-in or own).
  Future<void> update(TeamRole role) async {
    if (byId(role.id) == null) return;
    final saved = TeamRole(
      id: role.id,
      name: role.name.trim(),
      purpose: role.purpose.trim(),
      instructions: role.instructions.trim(),
      model: role.model != null && isValidTeamModel(role.model!)
          ? role.model
          : null,
      builtIn: TeamRoleIds.builtIn.contains(role.id),
    );
    final index = _roles.indexWhere((r) => r.id == role.id);
    _roles = [..._roles];
    if (index < 0) {
      _roles.add(saved);
    } else {
      _roles[index] = saved;
    }
    await _saveRoles();
  }

  /// Removes one of the person's own roles; built-ins cannot be removed.
  /// Tasks that had it keep showing its last name.
  Future<void> remove(String roleId) async {
    if (TeamRoleIds.builtIn.contains(roleId)) return;
    if (_roles.every((r) => r.id != roleId)) return;
    _roles = [
      for (final r in _roles)
        if (r.id != roleId) r,
    ];
    await _saveRoles();
  }

  /// Puts a built-in role back to how it shipped.
  Future<void> reset(String roleId) async {
    if (!TeamRoleIds.builtIn.contains(roleId)) return;
    if (_roles.every((r) => r.id != roleId)) return;
    _roles = [
      for (final r in _roles)
        if (r.id != roleId) r,
    ];
    await _saveRoles();
  }

  static final _wordSplit = RegExp(r'[^a-z0-9]+');

  static Set<String> _words(String text) => {
    for (final w in text.toLowerCase().split(_wordSplit))
      if (w.length >= 3) w,
  };

  /// The role the app suggests for a task, from its words (no network, no
  /// model call): matched against each role's name and purpose plus a
  /// small built-in vocabulary per built-in role. [TeamRoleIds.general]
  /// when nothing stands out.
  ///
  /// Scoring: one point per vocabulary term found in the text (a term
  /// matches as a whole word, or as a phrase for multi-word terms) and one
  /// per word of a role's name or purpose found in the text. The highest
  /// score wins; a tie or no score is general.
  String suggest(String taskText) {
    final text = ' ${taskText.toLowerCase().replaceAll(_wordSplit, ' ')} ';
    final words = _words(taskText);
    var best = TeamRoleIds.general;
    var bestScore = 0;
    var tied = false;
    for (final role in roles) {
      if (role.id == TeamRoleIds.general) continue;
      var score = 0;
      for (final term in TeamRoles.vocabulary[role.id] ?? const <String>[]) {
        if (text.contains(' $term ')) score++;
      }
      for (final w in _words('${role.name} ${role.purpose}')) {
        if (words.contains(w)) score++;
      }
      if (score == 0) continue;
      if (score > bestScore) {
        best = role.id;
        bestScore = score;
        tied = false;
      } else if (score == bestScore) {
        tied = true;
      }
    }
    return tied ? TeamRoleIds.general : best;
  }

  /// The role a task was given, or null (tasks from before roles, or
  /// given elsewhere).
  String? roleOfTask(String workOrRunId) => _taskRoles[workOrRunId];

  /// The role of a run: a run is linked to its work items by
  /// `WorkItem.runId`, and roles are remembered under the work id, so the
  /// first of [team]'s work items of [run] with a remembered role answers.
  /// A role remembered under the run id itself wins.
  String? roleOfRun(OrchestrationRun run, OrchestrationController team) {
    final direct = _taskRoles[run.id];
    if (direct != null) return direct;
    for (final item in team.snapshot.work) {
      if (item.runId == run.id) {
        final role = _taskRoles[item.id];
        if (role != null) return role;
      }
    }
    return null;
  }

  /// Remembers [roleId] for [workOrRunId].
  Future<void> rememberTaskRole(String workOrRunId, String roleId) async {
    if (workOrRunId.isEmpty) return;
    _taskRoles = {..._taskRoles, workOrRunId: roleId};
    notifyListeners();
    try {
      await prefs.setString(taskRolesKey(profileId), jsonEncode(_taskRoles));
    } catch (_) {
      // Session-only if the store refuses.
    }
  }
}

final _controllers = <String, TeamRolesController>{};

/// One [TeamRolesController] per profile (and per preferences instance).
TeamRolesController teamRolesFor(SharedPreferences prefs, String profileId) {
  final cached = _controllers[profileId];
  if (cached != null && identical(cached.prefs, prefs)) return cached;
  return _controllers[profileId] = TeamRolesController(prefs, profileId);
}

/// The description the worker receives: the role's instructions, then the
/// person's own description. Plain text; returns [description] unchanged
/// for a role without instructions.
String describeTaskForRole(TeamRole role, String? description) {
  final instructions = role.instructions.trim();
  if (instructions.isEmpty) return description ?? '';
  final name = role.name.trim().isEmpty ? role.id : role.name.trim();
  final task = (description ?? '').trim();
  return 'Role: $name\n$instructions\n\n---\n\n$task';
}

/// Gives a task to the team as [role]: applies the role's model (or the
/// team's model when the role has none) through [applyModel] before the
/// hand-over — the in-app team's `BuiltinTeam.applyModel`; null for a
/// team on a computer, whose model the host decides — then
/// [OrchestrationController.giveTask] with [describeTaskForRole], then
/// remembers the role for the created work id. Never throws past what
/// giveTask throws.
Future<({MutationRecord created, MutationRecord? assigned})> giveTaskAsRole({
  required OrchestrationController team,
  required TeamRolesController roles,
  required TeamRole role,
  required String title,
  String? description,
  required String projectId,
  required String agentId,
  String? teamModel,
  Future<void> Function(String? model)? applyModel,
  ValueChanged<MutationRecord>? onCreated,
}) async {
  if (applyModel != null) {
    try {
      await applyModel(role.model ?? teamModel);
    } catch (e) {
      // The task still goes; the worker keeps the model it had.
      debugPrint('team role model not applied: ${e.runtimeType}');
    }
  }
  final result = await team.giveTask(
    title: title,
    description: describeTaskForRole(role, description),
    projectId: projectId,
    agentId: agentId,
    onCreated: onCreated,
  );
  final receipt = result.created.receipt;
  final workId = receipt?.createdId;
  if (receipt != null && receipt.isAccepted && workId != null) {
    await roles.rememberTaskRole(workId, role.id);
  }
  return result;
}
