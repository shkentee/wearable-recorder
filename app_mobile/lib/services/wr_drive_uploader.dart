import 'dart:io';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:http/http.dart' as http;

/// MIME type used when uploading Opus-in-OGG dump files to Drive.
const _kOpusMime = 'audio/ogg; codecs=opus';

/// The Drive folder that all recordings are stored under.
const _kFolderName = 'wearable-recordings';

/// Drive API scope that allows creating / uploading files only.
const _kDriveScope = drive.DriveApi.driveFileScope;

// ---------------------------------------------------------------------------
// Private HTTP client that injects Google auth headers into every request.
// ---------------------------------------------------------------------------

class _GoogleAuthClient extends http.BaseClient {
  _GoogleAuthClient(this._headers);

  final Map<String, String> _headers;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(_headers);
    return _inner.send(request);
  }

  @override
  void close() {
    _inner.close();
    super.close();
  }
}

// ---------------------------------------------------------------------------
// Public service
// ---------------------------------------------------------------------------

/// Uploads recorded .opus dump files from the local device to Google Drive.
///
/// Dependency-injection-friendly: pass a pre-configured [GoogleSignIn]
/// instance (useful in tests). When omitted, a default instance scoped to
/// [drive.DriveApi.driveFileScope] is created.
///
/// For unit-testing without network access use the [WrDriveUploader.withApi]
/// factory, which injects a mock [drive.DriveApi] directly and skips
/// the Google sign-in flow entirely.
///
/// Example:
/// ```dart
/// final uploader = WrDriveUploader();
/// final fileId = await uploader.uploadFile(localFile, 'session-1234.opus');
/// ```
class WrDriveUploader {
  WrDriveUploader({GoogleSignIn? googleSignIn})
      : _googleSignIn =
            googleSignIn ?? GoogleSignIn(scopes: [_kDriveScope]),
        _apiOverride = null;

  /// Test-only constructor that bypasses Google sign-in entirely and uses the
  /// provided [drive.DriveApi] mock for all Drive calls.
  WrDriveUploader.withApi(drive.DriveApi api)
      : _googleSignIn = GoogleSignIn(scopes: [_kDriveScope]),
        _apiOverride = api;

  final GoogleSignIn _googleSignIn;

  /// When non-null, [_buildApi] returns this directly (used in tests).
  final drive.DriveApi? _apiOverride;

  // Cache the folder ID so repeated uploads in one session skip the search.
  String? _cachedFolderId;

  /// Signs in (or re-uses an existing session) and returns an authenticated
  /// [drive.DriveApi] instance backed by a [_GoogleAuthClient].
  ///
  /// If [_apiOverride] is set (test-only), returns it directly.
  Future<drive.DriveApi> _buildApi() async {
    final override = _apiOverride;
    if (override != null) return override;

    GoogleSignInAccount? account = _googleSignIn.currentUser;
    account ??= await _googleSignIn.signInSilently();
    account ??= await _googleSignIn.signIn();

    if (account == null) {
      throw StateError('Google Sign-In cancelled or failed.');
    }

    final authHeaders = await account.authHeaders;
    final client = _GoogleAuthClient(authHeaders);
    return drive.DriveApi(client);
  }

  /// Returns the Drive folder ID for [_kFolderName], creating it if needed.
  ///
  /// The result is cached for the lifetime of this [WrDriveUploader] instance.
  Future<String> _ensureFolder(drive.DriveApi api) async {
    final cached = _cachedFolderId;
    if (cached != null) return cached;

    // Search for an existing folder with the expected name owned by the user.
    final query =
        "mimeType='application/vnd.google-apps.folder' and name='$_kFolderName' and trashed=false";
    final result = await api.files.list(
      q: query,
      spaces: 'drive',
      $fields: 'files(id,name)',
    );

    final files = result.files;
    if (files != null && files.isNotEmpty) {
      _cachedFolderId = files.first.id!;
      return _cachedFolderId!;
    }

    // Folder not found — create it.
    final folder = drive.File()
      ..name = _kFolderName
      ..mimeType = 'application/vnd.google-apps.folder';
    final created = await api.files.create(folder);
    _cachedFolderId = created.id!;
    return _cachedFolderId!;
  }

  /// Uploads [localFile] to the "wearable-recordings/" Drive folder.
  ///
  /// [remoteFileName] is the name the file will have on Drive (e.g.
  /// `"session-1234.opus"`). Returns the newly created Drive file ID.
  ///
  /// Throws [StateError] if the user cancels sign-in, or re-throws any
  /// Drive API error.
  Future<String> uploadFile(File localFile, String remoteFileName) async {
    final api = await _buildApi();
    final folderId = await _ensureFolder(api);

    final meta = drive.File()
      ..name = remoteFileName
      ..parents = [folderId];

    final media = drive.Media(
      localFile.openRead(),
      await localFile.length(),
      contentType: _kOpusMime,
    );

    final created = await api.files.create(
      meta,
      uploadMedia: media,
    );

    final id = created.id;
    if (id == null) {
      throw StateError('Drive API returned a file with no ID.');
    }
    return id;
  }
}
