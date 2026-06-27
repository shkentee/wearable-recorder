import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_recorder/pages/settings_page.dart';
import 'package:wearable_recorder/services/wr_drive_uploader.dart';

class _MockUploader extends Mock implements WrDriveUploader {}

Widget _app(WrDriveUploader uploader) {
  return MaterialApp(home: SettingsPage(uploader: uploader));
}

void main() {
  late _MockUploader uploader;

  setUp(() {
    uploader = _MockUploader();
    when(() => uploader.currentEmail()).thenAnswer((_) async => null);
    when(() => uploader.clearFolderCache()).thenReturn(null);
  });

  testWidgets('shows the project recordings folder by default', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(_app(uploader));
    await tester.pumpAndSettle();

    expect(find.text('coai › recordings'), findsOneWidget);
    expect(find.text('wearable-recordings'), findsNothing);
  });

  testWidgets('resolves a selected recordings folder id into a display path',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'wr_drive_folder_id': 'recordings-folder-id',
      'wr_drive_folder': 'recordings',
    });
    when(() => uploader.folderDisplayPath('recordings-folder-id'))
        .thenAnswer((_) async => 'My Drive › coai › recordings');

    await tester.pumpWidget(_app(uploader));
    await tester.pumpAndSettle();

    expect(find.text('coai › recordings'), findsOneWidget);
    expect(find.text('wearable-recordings'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wr_drive_folder_display'), 'coai › recordings');
  });

  testWidgets('resets a legacy wearable folder id to the project default',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'wr_drive_folder_id': 'legacy-folder-id',
      'wr_drive_folder': 'wearable-recordings',
      'wr_drive_folder_display': 'マイドライブ › wearable-recordings',
    });

    await tester.pumpWidget(_app(uploader));
    await tester.pumpAndSettle();

    expect(find.text('coai › recordings'), findsOneWidget);
    expect(find.textContaining('wearable-recordings'), findsNothing);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('wr_drive_folder'), 'recordings');
    expect(prefs.getString('wr_drive_folder_id'), isNull);
    expect(prefs.getString('wr_drive_folder_display'), 'coai › recordings');
    verify(() => uploader.clearFolderCache()).called(greaterThanOrEqualTo(1));
    verifyNever(() => uploader.folderDisplayPath('legacy-folder-id'));
  });
}
