import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wearable_recorder/pages/device_page.dart';
import 'package:wearable_recorder/services/wr_ble_device.dart';

/// Mocktail mock of the [WrBleDevice] wrapper. Mocking the wrapper —
/// rather than [BluetoothDevice] — means the widget test never reaches
/// the flutter_blue_plus platform channel.
class _MockDevice extends Mock implements WrBleDevice {}

void main() {
  late _MockDevice device;
  late StreamController<BluetoothConnectionState> stateCtrl;
  late StreamController<int> packetCtrl;
  late StreamController<int> bytesCtrl;
  late Completer<void> connectCompleter;

  setUp(() {
    device = _MockDevice();
    stateCtrl = StreamController<BluetoothConnectionState>.broadcast();
    packetCtrl = StreamController<int>.broadcast();
    bytesCtrl = StreamController<int>.broadcast();
    connectCompleter = Completer<void>();

    when(() => device.name).thenReturn('Omi DK1');
    when(() => device.id).thenReturn('aa:bb:cc:dd:ee:01');
    when(() => device.state).thenAnswer((_) => stateCtrl.stream);
    when(() => device.packetCount).thenAnswer((_) => packetCtrl.stream);
    when(() => device.bytesSaved).thenAnswer((_) => bytesCtrl.stream);
    // DevicePage._connect calls device.connect() with no args, so we
    // only need to stub that form. Returning a Completer-controlled
    // future lets individual tests decide when to resolve / fail it.
    when(() => device.connect()).thenAnswer((_) => connectCompleter.future);
    when(() => device.dispose()).thenAnswer((_) async {});
  });

  tearDown(() async {
    if (!connectCompleter.isCompleted) connectCompleter.complete();
    await stateCtrl.close();
    await packetCtrl.close();
    await bytesCtrl.close();
  });

  Widget hostedDevicePage() {
    return MaterialApp(home: DevicePage(device: device));
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
}
