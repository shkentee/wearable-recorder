import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wearable_recorder/services/wr_sync_schedule.dart';

void main() {
  group('SyncSchedule.shouldStart', () {
    test('scheduledTime runs once after the configured minute each day', () {
      const schedule = SyncSchedule(
        mode: SyncMode.scheduledTime,
        timeMinutes: 23 * 60,
      );

      expect(schedule.shouldStart(DateTime(2026, 6, 27, 22, 59)), isFalse);
      expect(schedule.shouldStart(DateTime(2026, 6, 27, 23, 0)), isTrue);
      expect(
        schedule.shouldStart(
          DateTime(2026, 6, 27, 23, 30),
          lastScheduledDate: DateTime(2026, 6, 27, 23, 5),
        ),
        isFalse,
      );
      expect(
        schedule.shouldStart(
          DateTime(2026, 6, 28, 23, 0),
          lastScheduledDate: DateTime(2026, 6, 27, 23, 5),
        ),
        isTrue,
      );
    });

    test('intervalWindow supports windows that cross midnight', () {
      const schedule = SyncSchedule(
        mode: SyncMode.intervalWindow,
        intervalMin: 30,
        windowStartMin: 22 * 60,
        windowEndMin: 2 * 60,
      );

      expect(schedule.shouldStart(DateTime(2026, 6, 27, 21, 59)), isFalse);
      expect(schedule.shouldStart(DateTime(2026, 6, 27, 22, 0)), isTrue);
      expect(schedule.shouldStart(DateTime(2026, 6, 28, 1, 0)), isTrue);
      expect(
        schedule.shouldStart(
          DateTime(2026, 6, 28, 1, 20),
          lastIntervalRun: DateTime(2026, 6, 28, 1, 0),
        ),
        isFalse,
      );
      expect(
        schedule.shouldStart(
          DateTime(2026, 6, 28, 1, 30),
          lastIntervalRun: DateTime(2026, 6, 28, 1, 0),
        ),
        isTrue,
      );
    });

    test('manual mode never starts without an explicit UI trigger', () {
      const schedule = SyncSchedule(mode: SyncMode.manual);

      expect(schedule.shouldStart(DateTime(2026, 6, 27, 23, 0)), isFalse);
    });
  });

  group('SyncSchedule.load defaults', () {
    test('defaults to continuous sync for reliability', () async {
      SharedPreferences.setMockInitialValues({});

      final schedule = await SyncSchedule.load();
      final prefs = await SharedPreferences.getInstance();

      expect(schedule.mode, SyncMode.continuous);
      expect(prefs.getInt('wr_sched_mode'), SyncMode.continuous.index);
    });

    test('migrates legacy daily 23:00 setting to continuous sync once',
        () async {
      SharedPreferences.setMockInitialValues({
        'wr_sched_mode': SyncMode.scheduledTime.index,
        'wr_sched_time': 23 * 60,
      });

      final schedule = await SyncSchedule.load();
      final prefs = await SharedPreferences.getInstance();

      expect(schedule.mode, SyncMode.continuous);
      expect(prefs.getInt('wr_sched_mode'), SyncMode.continuous.index);
    });

    test('keeps scheduled mode after the continuous-default migration is done',
        () async {
      SharedPreferences.setMockInitialValues({
        'wr_sched_continuous_default_v2': true,
        'wr_sched_mode': SyncMode.scheduledTime.index,
        'wr_sched_time': 23 * 60,
      });

      final schedule = await SyncSchedule.load();

      expect(schedule.mode, SyncMode.scheduledTime);
      expect(schedule.timeMinutes, 23 * 60);
    });
  });
}
