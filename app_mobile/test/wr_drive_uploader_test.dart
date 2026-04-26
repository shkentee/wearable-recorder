import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:googleapis/drive/v3.dart' as drive;
import 'package:google_sign_in/google_sign_in.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wearable_recorder/services/wr_drive_uploader.dart';

// ---------------------------------------------------------------------------
// Mocks
// ---------------------------------------------------------------------------

class _MockGoogleSignIn extends Mock implements GoogleSignIn {}

class _MockDriveApi extends Mock implements drive.DriveApi {}

class _MockFilesResource extends Mock implements drive.FilesResource {}

// ---------------------------------------------------------------------------
// Fakes (required by mocktail for any() / captureAny() with custom types)
// ---------------------------------------------------------------------------

class _FakeDriveFile extends Fake implements drive.File {}

class _FakeMedia extends Fake implements drive.Media {}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Creates a temporary file pre-filled with [content] bytes.
Future<File> _tempOpusFile([String content = 'fake opus data']) async {
  final dir = Directory.systemTemp.createTempSync('wr_uploader_test_');
  return File('${dir.path}/session.opus')
    ..writeAsBytesSync(content.codeUnits);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    registerFallbackValue(_FakeDriveFile());
    registerFallbackValue(_FakeMedia());
  });

  late _MockDriveApi mockApi;
  late _MockFilesResource mockFiles;
  late _MockGoogleSignIn mockSignIn;

  setUp(() {
    mockApi = _MockDriveApi();
    mockFiles = _MockFilesResource();
    mockSignIn = _MockGoogleSignIn();

    // DriveApi.files delegate to the files resource mock.
    when(() => mockApi.files).thenReturn(mockFiles);
  });

  group('WrDriveUploader.uploadFile', () {
    // ------------------------------------------------------------------
    // Scenario 1: folder does not exist yet — should create it, then upload.
    // ------------------------------------------------------------------
    test(
        'creates folder when none exists and uploads with correct MIME type',
        () async {
      // list() returns empty — no folder found.
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer((_) async => drive.FileList()..files = []);

      // First create() = folder, second create() = uploaded file.
      // Capture uploadMedia via thenAnswer to avoid the two-captureAny pitfall
      // (verify with captureAny for a named arg also matches calls that omit
      // the arg, producing null in the captured list).
      when(() => mockFiles.create(any()))
          .thenAnswer((_) async => drive.File()..id = 'folder-id-123');
      drive.Media? capturedMedia;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((inv) async {
        capturedMedia = inv.namedArguments[#uploadMedia] as drive.Media;
        return drive.File()..id = 'file-id-abc';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      final fileId = await uploader.uploadFile(dumpFile, 'session-0001.opus');

      expect(fileId, 'file-id-abc');

      // list() must have been called to look for the folder.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(1);

      // Verify MIME type from the captured media object.
      expect(capturedMedia?.contentType, 'audio/ogg; codecs=opus');
    });

    // ------------------------------------------------------------------
    // Scenario 2: folder exists — should re-use it without creating again.
    // ------------------------------------------------------------------
    test('uses existing folder returned by Drive list()', () async {
      final existingFolder = drive.File()
        ..id = 'existing-folder-id'
        ..name = 'wearable-recordings';

      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((_) async => drive.File()..id = 'uploaded-file-id');

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      final fileId = await uploader.uploadFile(dumpFile, 'session.opus');
      expect(fileId, 'uploaded-file-id');

      // Folder create (no uploadMedia) must NOT be called.
      verifyNever(() => mockFiles.create(any()));
    });

    // ------------------------------------------------------------------
    // Scenario 3: folder ID is cached — list() called only once.
    // ------------------------------------------------------------------
    test('caches folder ID so list() is called only once across uploads',
        () async {
      final existingFolder = drive.File()..id = 'folder-cached';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      var uploadCount = 0;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((_) async {
        uploadCount++;
        return drive.File()..id = 'f-$uploadCount';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await uploader.uploadFile(dumpFile, 'a.opus');
      await uploader.uploadFile(dumpFile, 'b.opus');

      // Only one list() even though we uploaded twice.
      verify(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).called(1);
    });

    // ------------------------------------------------------------------
    // Scenario 4: Drive returns a file with no ID — should throw.
    // ------------------------------------------------------------------
    test('throws StateError when Drive API returns a file with no ID',
        () async {
      final existingFolder = drive.File()..id = 'folder-x';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((_) async => drive.File()); // id == null

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await expectLater(
        () => uploader.uploadFile(dumpFile, 'bad.opus'),
        throwsA(isA<StateError>()),
      );
    });

    // ------------------------------------------------------------------
    // Scenario 5: Google Sign-In cancelled — should throw StateError.
    // ------------------------------------------------------------------
    test('throws StateError when Google Sign-In is cancelled', () async {
      when(() => mockSignIn.currentUser).thenReturn(null);
      when(() => mockSignIn.signInSilently()).thenAnswer((_) async => null);
      when(() => mockSignIn.signIn()).thenAnswer((_) async => null);

      final dumpFile = await _tempOpusFile();
      // Use the standard constructor with the mock sign-in (no API override).
      final uploader = WrDriveUploader(googleSignIn: mockSignIn);

      await expectLater(
        () => uploader.uploadFile(dumpFile, 'session.opus'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('cancelled'),
          ),
        ),
      );
    });

    // ------------------------------------------------------------------
    // Scenario 6: remoteFileName is stored as the Drive file name.
    // ------------------------------------------------------------------
    test('sets correct remote file name in Drive metadata', () async {
      final existingFolder = drive.File()..id = 'f-folder';
      when(() => mockFiles.list(
            q: any(named: 'q'),
            spaces: any(named: 'spaces'),
            $fields: any(named: r'$fields'),
          )).thenAnswer(
        (_) async => drive.FileList()..files = [existingFolder],
      );

      drive.File? capturedMeta;
      when(() => mockFiles.create(
            any(),
            uploadMedia: any(named: 'uploadMedia'),
          )).thenAnswer((invocation) async {
        capturedMeta = invocation.positionalArguments.first as drive.File;
        return drive.File()..id = 'new-id';
      });

      final dumpFile = await _tempOpusFile();
      final uploader = WrDriveUploader.withApi(mockApi);

      await uploader.uploadFile(dumpFile, 'my-custom-name.opus');

      expect(capturedMeta?.name, 'my-custom-name.opus');
      expect(capturedMeta?.parents, contains('f-folder'));
    });
  });
}
