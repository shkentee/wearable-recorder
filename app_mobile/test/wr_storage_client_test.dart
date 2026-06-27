import 'dart:async';
import 'dart:io';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:wearable_recorder/services/wr_storage_client.dart';

class _MockCharacteristic extends Mock implements BluetoothCharacteristic {}

Future<void> _letSubscriptionRegister() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  late _MockCharacteristic mockStream;
  late _MockCharacteristic mockCtrl;
  late StreamController<List<int>> streamCtrl;
  late List<List<int>> writes;

  setUp(() {
    mockStream = _MockCharacteristic();
    mockCtrl = _MockCharacteristic();
    streamCtrl = StreamController<List<int>>.broadcast();
    writes = [];

    when(() => mockStream.setNotifyValue(true)).thenAnswer((_) async => true);
    when(() => mockStream.setNotifyValue(false)).thenAnswer((_) async => true);
    when(() => mockStream.onValueReceived).thenAnswer((_) => streamCtrl.stream);
    when(() => mockCtrl.write(any(),
            withoutResponse: any(named: 'withoutResponse')))
        .thenAnswer((invocation) async {
      writes.add(List<int>.from(invocation.positionalArguments.first as List));
    });
  });

  tearDown(() async {
    await streamCtrl.close();
  });

  WrStorageSession makeSession() => WrStorageSession.forTest(
        stream: mockStream,
        ctrl: mockCtrl,
      );

  Future<void> waitForWrites(int count) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (writes.length < count) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for $count write(s); saw ${writes.length}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  group('listFiles', () {
    test('returns filenames from FILE_ENTRY notifies then END', () async {
      final session = makeSession();
      final future = session.listFiles();

      await _letSubscriptionRegister();
      streamCtrl.add([0x01, ...('1700000000.opus'.codeUnits)]);
      streamCtrl.add([0x01, ...('unsynced_ab12_00000.opus'.codeUnits)]);
      streamCtrl.add([0x03]); // END

      final files = await future;
      expect(files, [
        '1700000000.opus',
        'unsynced_ab12_00000.opus',
      ]);
    });

    test('sends LIST command byte 0x00', () async {
      final session = makeSession();
      final future = session.listFiles();
      await _letSubscriptionRegister();
      streamCtrl.add([0x03]);
      await future;

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [0x00]);
    });

    test('returns empty list when no files before END', () async {
      final session = makeSession();
      final future = session.listFiles();
      await _letSubscriptionRegister();
      streamCtrl.add([0x03]);
      expect(await future, isEmpty);
    });

    test('throws StateError on ERROR notify', () async {
      final session = makeSession();
      final future = session.listFiles();
      await _letSubscriptionRegister();
      streamCtrl.add([0xFF]);
      expect(future, throwsA(isA<StateError>()));
    });
  });

  group('fetchFile', () {
    test('concatenates DATA chunks until END', () async {
      final session = makeSession();
      final future = session.fetchFile('1700000000.opus');
      await _letSubscriptionRegister();

      // Two data chunks of 3 bytes each.
      streamCtrl.add([0x02, 0x01, 0x02, 0x03]);
      streamCtrl.add([0x02, 0x04, 0x05, 0x06]);
      streamCtrl.add([0x03]); // END

      final bytes = await future;
      expect(bytes, [0x01, 0x02, 0x03, 0x04, 0x05, 0x06]);
    });

    test('sends FETCH command with filename bytes', () async {
      final session = makeSession();
      final future = session.fetchFile('test.opus');
      await _letSubscriptionRegister();
      streamCtrl.add([0x03]);
      await future;

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [
        0x01,
        0x00, 0x00, 0x00, 0x00, // offset = 0
        0x00, 0x00, 0x00, 0x00, // length = 0, fetch to EOF
        ...'test.opus'.codeUnits,
      ]);
    });

    test('reports progress via onProgress callback', () async {
      final session = makeSession();
      final progress = <int>[];
      final future = session.fetchFile(
        'f.opus',
        onProgress: progress.add,
      );
      await _letSubscriptionRegister();
      streamCtrl.add([0x02, 0xAA, 0xBB]); // 2 bytes
      streamCtrl.add([0x02, 0xCC]); // 1 byte
      streamCtrl.add([0x03]);
      await future;

      expect(progress, [2, 3]);
    });

    test('throws StateError when device sends ERROR', () async {
      final session = makeSession();
      final future = session.fetchFile('missing.opus');
      await _letSubscriptionRegister();
      streamCtrl.add([0xFF]);
      expect(future, throwsA(isA<StateError>()));
    });
  });

  group('fetchFileToFile', () {
    test('streams long files through bounded windows', () async {
      final session = makeSession();
      final temp = await Directory.systemTemp.createTemp('wr_storage_test_');
      addTearDown(() async {
        if (await temp.exists()) await temp.delete(recursive: true);
      });
      final out = File('${temp.path}/long.opus');
      final progress = <String>[];

      final future = session.fetchFileToFile(
        'long.opus',
        out,
        windowSize: 4,
        onProgress: (bytes, total) => progress.add('$bytes/$total'),
      );

      await waitForWrites(1);
      streamCtrl.add([0x04, 10, 0, 0, 0]);
      streamCtrl.add([0x02, 1, 2]);
      streamCtrl.add([0x02, 3, 4]);
      streamCtrl.add([0x03]);

      await waitForWrites(2);
      streamCtrl.add([0x04, 10, 0, 0, 0]);
      streamCtrl.add([0x02, 5, 6, 7, 8]);
      streamCtrl.add([0x03]);

      await waitForWrites(3);
      streamCtrl.add([0x04, 10, 0, 0, 0]);
      streamCtrl.add([0x02, 9, 10]);
      streamCtrl.add([0x03]);

      expect(await future.timeout(const Duration(seconds: 2)), 10);
      expect(await out.readAsBytes(), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
      expect(progress, ['4/10', '8/10', '10/10']);

      final fetchCommands = writes.where((cmd) => cmd.first == 0x01).toList();
      expect(fetchCommands, hasLength(3));
      expect(fetchCommands[0].sublist(1, 5), [0, 0, 0, 0]);
      expect(fetchCommands[1].sublist(1, 5), [4, 0, 0, 0]);
      expect(fetchCommands[2].sublist(1, 5), [8, 0, 0, 0]);
      for (final cmd in fetchCommands) {
        expect(cmd.sublist(5, 9), [4, 0, 0, 0]);
      }
    });
  });

  group('abort', () {
    test('sends ABORT command byte 0xFF', () async {
      final session = makeSession();
      await session.abort();

      final captured = verify(
        () => mockCtrl.write(captureAny(),
            withoutResponse: any(named: 'withoutResponse')),
      ).captured;
      expect(captured.first, [0xFF]);
    });
  });
}
