import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_recorder/pages/device_page.dart';
import 'package:wearable_recorder/pages/drive_files_page.dart';
import 'package:wearable_recorder/pages/storage_page.dart';
import 'package:wearable_recorder/services/wr_ble_device.dart';
import 'package:wearable_recorder/services/wr_drive_uploader.dart';

/// Mocktail mock of the [WrBleDevice] wrapper. Mocking the wrapper —
/// rather than [BluetoothDevice] — means the widget test never reaches
/// the flutter_blue_plus platform channel.
class _MockDevice extends Mock implements WrBleDevice {}

/// Mocktail mock of [WrDriveUploader] — used to inject into [DevicePage] so
/// the [DriveFilesPage] path never tries to reach Google Sign-In.
class _MockUploader extends Mock implements WrDriveUploader {}

void main() {
  late _MockDevice device;
  late StreamController<BluetoothConnectionState> stateCtrl;
  late StreamController<int> packetCtrl;
  late StreamController<int> bytesCtrl;
  late StreamController<int> lostCtrl;
  late StreamController<int> batteryCtrl;
  late Completer<void> connectCompleter;
  late _MockUploader mockUploader;

  setUp(() {
    // Stub SharedPreferences so DevicePage._connect() (which saves the device
    // id after a successful connect) never touches the real platform channel.
    SharedPreferences.setMockInitialValues({});
    device = _MockDevice();
    stateCtrl = StreamController<BluetoothConnectionState>.broadcast();
    packetCtrl = StreamController<int>.broadcast();
    bytesCtrl = StreamController<int>.broadcast();
    lostCtrl = StreamController<int>.broadcast();
    batteryCtrl = StreamController<int>.broadcast();
    connectCompleter = Completer<void>();
    mockUploader = _MockUploader();

    when(() => device.name).thenReturn('Omi DK1');
    when(() => device.id).thenReturn('aa:bb:cc:dd:ee:01');
    when(() => device.state).thenAnswer((_) => stateCtrl.stream);
    when(() => device.packetCount).thenAnswer((_) => packetCtrl.stream);
    when(() => device.bytesSaved).thenAnswer((_) => bytesCtrl.stream);
    when(() => device.lostPackets).thenAnswer((_) => lostCtrl.stream);
    when(() => device.batteryLevel).thenAnswer((_) => batteryCtrl.stream);
    // DevicePage._connect calls device.connect() with no args, so we
    // only need to stub that form. Returning a Completer-controlled
    // future lets individual tests decide when to resolve / fail it.
    when(() => device.connect()).thenAnswer((_) => connectCompleter.future);
    when(() => device.dispose()).thenAnswer((_) async {});
    // StoragePage.initState calls openStorageSession(); null = service not found.
    when(() => device.openStorageSession()).thenAnswer((_) async => null);
    // DriveFilesPage.initState calls listFiles().
    when(() => mockUploader.listFiles()).thenAnswer((_) async => []);
  });

  tearDown(() async {
    if (!connectCompleter.isCompleted) connectCompleter.complete();
    await stateCtrl.close();
    await packetCtrl.close();
    await bytesCtrl.close();
    await lostCtrl.close();
    await batteryCtrl.close();
  });

  /// Default helper — no uploader override (used by tests that don't navigate
  /// to DriveFilesPage).
  Widget hostedDevicePage() {
    return MaterialApp(home: DevicePage(device: device));
  }

  /// Helper with injected [_MockUploader] for navigation tests that reach
  /// [DriveFilesPage].
  Widget hostedDevicePageWithUploader() {
    return MaterialApp(
      home: DevicePage(device: device, uploader: mockUploader),
    );
  }

  testWidgets('shows "connecting…" while the connect future is pending',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());
    // initState fires connect() but we never complete the future, so
    // the page should still be in its initial 'connecting…' state.
    expect(find.text('status: connecting…'), findsOneWidget);
    expect(find.text('audioCodec packets: 0'), findsOneWidget);
    expect(find.text('Saved bytes: 0'), findsOneWidget);
    expect(find.text('id: aa:bb:cc:dd:ee:01'), findsOneWidget);
    // App bar title comes from device.name.
    expect(find.text('Omi DK1'), findsOneWidget);
  });

  testWidgets('reflects connection state transitions on the state stream',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());

    stateCtrl.add(BluetoothConnectionState.connected);
    await tester.pumpAndSettle();
    expect(find.text('status: connected'), findsOneWidget);

    stateCtrl.add(BluetoothConnectionState.disconnected);
    await tester.pumpAndSettle();
    expect(find.text('status: disconnected'), findsOneWidget);
  });

  testWidgets('packet count text increments as packetCount stream emits',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());

    packetCtrl.add(1);
    await tester.pumpAndSettle();
    expect(find.text('audioCodec packets: 1'), findsOneWidget);

    packetCtrl.add(7);
    await tester.pumpAndSettle();
    expect(find.text('audioCodec packets: 7'), findsOneWidget);

    packetCtrl.add(123);
    await tester.pumpAndSettle();
    expect(find.text('audioCodec packets: 123'), findsOneWidget);
  });

  testWidgets('saved-bytes text updates when bytesSaved stream emits',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());

    bytesCtrl.add(160);
    await tester.pumpAndSettle();
    expect(find.text('Saved bytes: 160'), findsOneWidget);

    bytesCtrl.add(4096);
    await tester.pumpAndSettle();
    expect(find.text('Saved bytes: 4096'), findsOneWidget);
  });

  testWidgets('shows error status when connect() throws', (tester) async {
    // Override the default stub so the future fails instead of pending.
    when(() => device.connect())
        .thenAnswer((_) async => throw StateError('boom'));

    await tester.pumpWidget(hostedDevicePage());
    // Let the failing future settle so the catch block runs setState.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.textContaining('error:'), findsOneWidget);
    expect(find.textContaining('boom'), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // New tests
  // ---------------------------------------------------------------------------

  testWidgets('connect() is called once when the page initialises',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());

    // Resolve the pending connect future so the page settles cleanly.
    connectCompleter.complete();
    await tester.pumpAndSettle();

    // device.connect() must have been called exactly once by _connect().
    verify(() => device.connect()).called(1);
  });

  testWidgets(
      'sd_storage_outlined button navigates to StoragePage',
      (tester) async {
    await tester.pumpWidget(hostedDevicePage());

    // Let connect settle so the page is fully ready.
    connectCompleter.complete();
    await tester.pumpAndSettle();

    // Tap the SD-card icon in the AppBar.
    await tester.tap(find.byIcon(Icons.sd_storage_outlined));
    await tester.pumpAndSettle();

    // StoragePage should now be visible.
    expect(find.byType(StoragePage), findsOneWidget);
  });

  testWidgets(
      'cloud_queue button navigates to DriveFilesPage',
      (tester) async {
    // Use the helper that injects the mock uploader so DriveFilesPage never
    // tries to reach real Google Sign-In / Drive APIs.
    await tester.pumpWidget(hostedDevicePageWithUploader());

    // Let connect settle so the page is fully ready.
    connectCompleter.complete();
    await tester.pumpAndSettle();

    // Tap the cloud-queue icon in the AppBar.
    await tester.tap(find.byIcon(Icons.cloud_queue));
    await tester.pumpAndSettle();

    // DriveFilesPage should now be visible.
    expect(find.byType(DriveFilesPage), findsOneWidget);
  });
}
