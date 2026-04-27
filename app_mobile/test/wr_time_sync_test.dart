import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_recorder/services/wr_ble_device.dart';

void main() {
  group('WrBleDevice.epochToBytes', () {
    test('encodes 0 as 8 zero bytes', () {
      expect(WrBleDevice.epochToBytes(0), List.filled(8, 0));
    });

    test('encodes 1 as little-endian [1, 0, …, 0]', () {
      expect(WrBleDevice.epochToBytes(1), [1, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('encodes 256 (0x100) into byte 1', () {
      expect(WrBleDevice.epochToBytes(256), [0, 1, 0, 0, 0, 0, 0, 0]);
    });

    test('encodes 0x01020304 correctly', () {
      // 0x01020304 = 16909060
      // LE bytes: [0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00]
      expect(
        WrBleDevice.epochToBytes(0x01020304),
        [0x04, 0x03, 0x02, 0x01, 0x00, 0x00, 0x00, 0x00],
      );
    });

    test('encodes 2^32 (0x100000000) into byte 4', () {
      expect(
        WrBleDevice.epochToBytes(0x100000000),
        [0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00],
      );
    });

    test('always produces exactly 8 bytes', () {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(WrBleDevice.epochToBytes(now).length, 8);
    });
  });
}
