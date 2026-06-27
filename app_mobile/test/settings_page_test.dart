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
  });

  testWidgets('shows the project recordings folder by default', (tester) async {
    SharedPreferences.setMockInitialValues({});

    await tester.pumpWidget(_app(uploader));
    await tester.pumpAndSettle();

    expect(find.text('coai › recordings'), findsOneWidget);
    expect(find.text('wearable-recordings'), findsNothing);
  });

  testWidgets('migrates a legacy displayed folder name using the selected id',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'wr_drive_folder_id': 'recordings-folder-id',
      'wr_drive_folder': 'wearable-recordings',
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
}
