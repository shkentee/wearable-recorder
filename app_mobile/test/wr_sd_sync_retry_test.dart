import 'package:flutter_test/flutter_test.dart';
import 'package:wearable_recorder/services/wr_sd_sync.dart';

void main() {
  group('WrSdSync retry policy', () {
    test('closed file read retry grows with a bounded maximum', () {
      expect(
        WrSdSync.closedFileRetryDelayForAttempt(0),
        const Duration(seconds: 30),
      );
      expect(
        WrSdSync.closedFileRetryDelayForAttempt(1),
        const Duration(seconds: 30),
      );
      expect(
        WrSdSync.closedFileRetryDelayForAttempt(2),
        const Duration(seconds: 60),
      );
      expect(
        WrSdSync.closedFileRetryDelayForAttempt(3),
        const Duration(seconds: 120),
      );
      expect(
        WrSdSync.closedFileRetryDelayForAttempt(99),
        const Duration(minutes: 15),
      );
    });
  });
}
