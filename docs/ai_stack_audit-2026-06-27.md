# Stack/Long-Run Audit - 2026-06-27

Source: AI-generated verification notes from Codex session.
Timezone: JST (UTC+9).

## Conclusion

The current `wearable-recorder` mobile app was checked on a physical Android
device and updated to remove the remaining long-run stack/stall risks found in
the SD pull and upload paths.

Verified result:

- Real device did not stall during connect, recording-state display, manual pull
  trigger, SD listing, foreground-service operation, or 90-second background
  operation.
- The app process stayed alive in background with the Android foreground service
  active.
- The long-recording path no longer requires loading a full SD file into memory.
- SD files whose names do not contain an epoch, such as `rec_0005.opus_sd`, now
  get a stable per-file chunk base so emitted Drive chunk names do not collide.
- Drive metadata and upload calls now have bounded timeouts, so a network/API
  hang returns as a retryable failure instead of pinning the upload loop forever.

## Real-Device Evidence

Device:

- Model: `SM S931Q`
- Android package: `com.example.app_mobile`
- App PID during run: `15135`

Observed on the app screen:

- `Mojio Device`
- `接続中`
- Battery shown around `97%` to `98%`
- `SDに録音`: `オン — 本体に保存中`
- Pull mode: `タイマー：毎日 23:00`
- Manual pull card returned to `待機中`
- SD list loaded and showed `rec_0005.opus_sd` through visible `rec_0017.opus_sd`

Foreground/background evidence:

- `dumpsys activity services com.example.app_mobile` showed
  `com.pravera.flutter_foreground_task.service.ForegroundService`
- Service state: `isForeground=true`
- Notification id: `1001`
- Notification flags included `ONGOING_EVENT|NO_CLEAR|FOREGROUND_SERVICE`
- PID before and after 90 seconds in background remained `15135`
- App returned to foreground still connected

Log evidence:

- BLE connect completed with `GATT_SUCCESS`
- MTU negotiated to `247`
- Service discovery completed with `count: 12`
- Battery notifications continued while foreground/background state changed
- No app `FATAL EXCEPTION`, app crash, or app `SecurityException` was observed in
  the PID-filtered log.

Notes:

- The real 23:00 wall-clock arrival was not waited for in this session.
- Timer behavior is covered by unit tests for daily scheduled mode and interval
  windows, including crossing midnight.

## Theoretical Stack/Stall Review

### Long SD File Pull

Automatic sync already uses bounded reads:

- `WrSdSync._window = 64 * 1024`
- `WrSdSync._maxBytesPerPass = 1 * 1024 * 1024`
- `WrStorageSession.fetchWindow()` has an idle timeout and reads a bounded byte
  range.

The manual SD page previously used `fetchFile()` and accumulated the whole file
in memory before writing a temp file. That was a long-recording stall/OOM risk.

Fixed by adding:

- `WrStorageSession.fetchFileToFile(...)`
- `StoragePage._fetchAndUpload(...)` now streams bounded windows directly into a
  temp file, then uploads that file.

Unit test added:

- `wr_storage_client_test.dart`
- `fetchFileToFile streams long files through bounded windows`

This verifies multiple bounded fetch commands with offsets `0`, `4`, and `8` in
the test case, and verifies the file bytes are written in order.

### Chunk Name Collision

The real device exposes SD files named like `rec_0005.opus_sd`. These names do
not contain an epoch. The previous fallback chunk naming used the current phone
time and did not use `_chunkIndex`, so multiple emitted chunks could collide.

Fixed by:

- Adding a stable per-source-file base key: `wr_sync_base_<name>`
- Persisting the base for non-epoch SD names
- Emitting chunk names as `base + chunkIndex * chunkSeconds`
- Resetting the base if a device file shrinks/reuses a name

This prevents long backlog chunks from overwriting each other locally or
colliding in Drive.

### Upload Loop

The SD pull loop and Drive upload loop are decoupled by the local outbox.

Relevant behavior:

- Pulling can continue to create outbox chunks even when Drive is blocked.
- Wi-Fi-only mode pauses upload without blocking the pull loop.
- Upload errors leave files in outbox for retry.

Fixed remaining indefinite-wait risk:

- Drive folder lookup/create now uses a 30-second metadata timeout.
- Drive upload/create/update now uses a size-based timeout with a minimum of 2
  minutes.

### Timer

`SyncSchedule.shouldStart()` gates the modes:

- `scheduledTime`: starts once per day after the configured minute.
- `intervalWindow`: starts every configured interval inside the window and also
  supports windows crossing midnight.
- `manual`: does not start without explicit UI trigger.

Unit test added:

- `wr_sync_schedule_test.dart`

### Remaining Bounded Limits

There is no software path that can make BLE transfer faster than the physical
BLE link. If the device produces audio faster than BLE can drain for a very long
period, backlog can grow on the device SD. The app now handles that by keeping
each read bounded, persisting cursor state each window, interleaving live and
closed-file backlog, and resuming after transient errors instead of stalling.

## Verification Commands Run

- `flutter analyze`
- `flutter test --reporter compact`
- `flutter build apk --debug`
- `adb install -r build\app\outputs\flutter-apk\app-debug.apk`
- Real-device UI/notification/service/log checks with `adb`

All local Flutter tests passed after the changes.
