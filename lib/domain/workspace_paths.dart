/// Folders the app never uses as a workspace.
///
/// A home folder or a filesystem root is not a project: OpenCode would watch
/// and scan every dotfile, cache and package directory underneath it, and on a
/// phone that has already starved the server until chat stopped (a stray git
/// repository at `/` in the managed container made `/root` resolve to the
/// whole filesystem). The app therefore refuses these locations everywhere a
/// workspace is chosen or restored, and asks for a real project folder
/// instead.
library;

/// The folder the managed Termux server serves from and creates projects in.
const managedProjectsDirectory = '/root/projects';

/// Trailing separators dropped, backslashes unified, case kept.
String _normalize(String path) {
  var value = path.trim().replaceAll('\\', '/');
  while (value.length > 1 && value.endsWith('/')) {
    final trimmed = value.substring(0, value.length - 1);
    if (trimmed.endsWith(':')) break; // Keep a Windows drive root intact.
    value = trimmed;
  }
  return value;
}

final _driveRoot = RegExp(r'^[A-Za-z]:/?$');
final _windowsHome = RegExp(r'^[A-Za-z]:/Users/[^/]+$', caseSensitive: false);

/// True for `/`, a Windows drive root, and every home folder shape the
/// supported servers use: `/root`, `/home/<user>`, `/Users/<user>`, the
/// Termux home, and `~`. Empty and whitespace-only paths count too, because
/// the server resolves those to its own working directory.
bool isProtectedWorkspaceDirectory(String? path) {
  if (path == null) return true;
  final value = _normalize(path);
  if (value.isEmpty || value == '/' || value == '~') return true;
  if (_driveRoot.hasMatch(value) || _windowsHome.hasMatch(value)) return true;
  if (value == '/root' || value == '/home' || value == '/Users') return true;
  if (value == '/data/data/com.termux/files/home') return true;
  final segments = value.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.length == 2 &&
      (segments.first == 'home' || segments.first == 'Users')) {
    return true;
  }
  return false;
}

/// Plain-sentence reason a typed or restored [path] cannot be a workspace, or
/// null when it is acceptable as a project folder.
String? workspaceDirectoryProblem(String? path) {
  final value = path == null ? '' : _normalize(path);
  if (value.isEmpty) return 'Enter the full path of a project folder.';
  if (value.codeUnits.any((c) => c < 0x20)) {
    return 'The folder path contains characters that cannot be used.';
  }
  if (value.length > 4096) return 'The folder path is too long.';
  final absolute =
      value.startsWith('/') || RegExp(r'^[A-Za-z]:/').hasMatch(value);
  if (!absolute) return 'Enter an absolute path, starting with /.';
  if (isProtectedWorkspaceDirectory(value)) {
    return 'The home folder and the filesystem root cannot be used as a '
        'workspace. Choose a project folder inside them instead.';
  }
  return null;
}

final _folderName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$');

/// True for Android shared-storage paths (`/sdcard`, `/storage/emulated/0`,
/// removable volumes under `/storage`, `/mnt/media_rw`, …).
///
/// OpenCode inside the app runs in its own Ubuntu, which only sees the
/// folders bound into it (`/root/projects`); shared storage is not mounted
/// there, so `test -d /sdcard/…` fails even when the folder exists on the
/// phone. Without this check the app offers to "create" the folder and makes
/// an empty namesake inside its private files instead. A server in Termux
/// (with storage access granted) or on another machine may well see these
/// paths, so this is only a reason to refuse for the in-app server.
bool isPhoneSharedStoragePath(String? path) {
  if (path == null) return false;
  final value = _normalize(path);
  if (value == '/sdcard' || value.startsWith('/sdcard/')) return true;
  if (value == '/storage' || value.startsWith('/storage/')) return true;
  if (value == '/mnt/sdcard' || value.startsWith('/mnt/sdcard/')) {
    return true;
  }
  if (value == '/mnt/media_rw' || value.startsWith('/mnt/media_rw/')) {
    return true;
  }
  if (value == '/mnt/expand' || value.startsWith('/mnt/expand/')) return true;
  if (value == '/external_sd' || value.startsWith('/external_sd/')) {
    return true;
  }
  return false;
}

/// Why [path] cannot be opened on OpenCode inside the app, or null when it
/// can. Shared phone storage is not mounted into the app's Ubuntu; only a
/// plain sentence, so the localized dialog wrapper can carry it.
String? phoneSharedStorageProblem(String? path) {
  if (!isPhoneSharedStoragePath(path)) return null;
  return 'Phone storage (${_normalize(path!)}) is not visible to OpenCode '
      'inside the app, even when the folder exists on the phone. Move the '
      'project under $managedProjectsDirectory instead.';
}

/// Reason a new project folder [name] is unusable, or null when it is a
/// single safe path segment.
String? projectFolderNameProblem(String name) {
  final value = name.trim();
  if (value.isEmpty) return 'Enter a folder name.';
  if (value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\\')) {
    return 'Use a single folder name without slashes.';
  }
  if (!_folderName.hasMatch(value)) {
    return 'Use letters, digits, dots, dashes or underscores, starting with a '
        'letter or digit (up to 64 characters).';
  }
  return null;
}
