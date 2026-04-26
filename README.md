# wearable-recorder

[![firmware-build](https://github.com/shkentee/wearable-recorder/actions/workflows/build.yml/badge.svg)](https://github.com/shkentee/wearable-recorder/actions/workflows/build.yml)
[![bsim-smoke](https://github.com/shkentee/wearable-recorder/actions/workflows/bsim.yml/badge.svg)](https://github.com/shkentee/wearable-recorder/actions/workflows/bsim.yml) — 2-device GATT notify exchange を検証
[![tools](https://github.com/shkentee/wearable-recorder/actions/workflows/tools.yml/badge.svg)](https://github.com/shkentee/wearable-recorder/actions/workflows/tools.yml)

自作ウェアラブル録音デバイスのファームウェア。Seeed XIAO nRF52840 Sense + microSD で起きている間ずっと録音し、後でローカル faster-whisper large-v3 で文字起こしする。

[BasedHardware/omi](https://github.com/BasedHardware/omi) DK1+SPISD ベース、Plan B（常時SD書き込み）、ボタン長押しMSCモード、ハートビート式LED通知に改修。

## ステータス

**Phase 4-6+ 完了 / Phase 5 実機待ち** — bsim CI は `wr_smoke`（1-dev）+ `wr_link`（2-dev GATT 接続 verdict）まで安定 green。`wr_link` notify exchange は一度試したが kernel panic で revert（`bt_conn_cb_register()` 動的版で v2 再挑戦予定、§22.14）。Phase 6 は wr_chunk / wr_fifo / wr_msc 純化 + PC tools + Flutter skeleton + Android APK CI まで完了し、残るは実機 bring-up・Drive アップロード・`usb_enable()` runtime 切替。

ztest 約 90 本 + tools pytest 22 本（decode-dump 12 + power-predict 10）+ Flutter Dart テスト 25 本（widget 9 + unit 16）すべて green。

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | リポジトリ構築・仕様書（17決定事項）反映 | ✅ |
| Phase 2 | GitHub Actions ビルド CI（NCS v2.7-branch、UF2 アーティファクト）| ✅ |
| Phase 3 | Twister + native_sim サニティテスト（FIFO 閾値ユニットテスト）| ✅ |
| Phase 4 | Plan B / チャンク / FIFO / MSC / LED（5サブタスク MVP）| ✅ |
| Phase 4-5+ | LED picker 純化 + native_sim ztest 13本 | ✅ |
| Phase 4-6+ | wr_chunk / wr_fifo / wr_msc_mode 純化 + ztest 約47本（合計 約60本）| ✅ |
| Phase 5+ | BabbleSim CI（5 stage: -help → wr_smoke → wr_link 2-device GATT verdict）| ✅ |
| Phase 5 | 実機書き込み・電力測定（PPK2）| ⏳ → [Phase 5 quickstart](docs/phase5-quickstart.md) |
| Phase 6 | wr_chunk epoch/boot-id/size + wr_fifo classify (+18 ztest) + wr_msc runtime-mode (+13 ztest) + PC decoder (Opus→WAV) + power-predict + Flutter skeleton + widget tests + Android APK CI | 🟡 進行中（残: 実機 BLE / Drive アップロード / `usb_enable()` runtime 切替 / `wr_link` notify v2）|

詳細は [docs/wearable-recorder-spec.md](docs/wearable-recorder-spec.md) §22、Phase 5 実機 bring-up は [docs/phase5-quickstart.md](docs/phase5-quickstart.md)、bsim 設計は [docs/bsim-setup.md](docs/bsim-setup.md)、Phase 6 着手準備は [docs/phase6-plan-draft.md](docs/phase6-plan-draft.md) 参照。

### Phase 4 完了内容

- **4-1 Plan B**: omi `transport.c::pusher()` を ファンアウト構造に refactor（`app/patches/0001-plan-b-fanout-tx-queue.patch`）。BLE と SD 両方に同じ TX データを書き込み
- **4-2 チャンクローテーション (MVP)**: 10分タイマー → `chunk_NNNNN.opus` リネーム → 新 `a01.txt` 作成（連番命名のみ。UNIX_epoch / boot ID / サイズ閾値は Phase 6）
- **4-3 FIFO 自動削除**: 1分ごとに `fs_statvfs`、空き<10% で最古 chunk を unlink（録音中ファイルは除外）
- **4-4 USB MSC (MVP)**: 起動時 D5 長押し検出 → `wr_msc_mode_is_active()` フラグ。runtime mode-switch は Phase 5 実機検証後
- **4-5 LED 状態マシン**: 100ms tick で警告優先順位 + ハートビート。バッテリー ADC は Phase 5 でフック予定

### Phase 5 / Phase 6 未着手項目

- **Phase 5**: 実機書き込み（XIAO Sense UF2）、PPK2 電力測定、バッテリー ADC、MSC runtime 切替、Plan B 実機ジッター測定
- **Phase 6 残**: Google Drive アップロード、Foreground Service 常時接続、`performSyncTime()` 後のチャンク epoch 命名配線、`usb_enable()` runtime 切替、`wr_link` notify exchange v2（`bt_conn_cb_register()` 動的版、§22.14）、iOS APK ジョブ、release APK 署名

## メモリ予算（Phase 4 完了時点）

| リソース | 使用量 | 上限 | 使用率 |
|---|---|---|---|
| FLASH | 318,204 B | 788 KB | 39.43% |
| RAM | 191,096 B | 256 KB | 72.90% |

## ディレクトリ構成

```
.
├── app/                            # けんた独自コード（Plan B / FIFO / MSC / LED）
│   ├── overlay/
│   │   └── spisd-fixup.conf        # omi prj.conf の修正・補完
│   ├── patches/
│   │   ├── 0001-plan-b-fanout-tx-queue.patch
│   │   └── 0002-cmake-add-app-sources.patch
│   ├── include/                    # 純粋ロジックの公開ヘッダ（ztest からも参照）
│   │   ├── wr_chunk_logic.h
│   │   ├── wr_fifo_logic.h
│   │   ├── wr_led_pick.h
│   │   └── wr_msc_mode_logic.h
│   └── src/
│       ├── wr_chunk.c              # 10分チャンクローテーション（Zephyr グルー）
│       ├── wr_chunk_logic.c        # 純粋ロジック（命名 / 述語 / boot ID）
│       ├── wr_fifo.c               # 空き10%以下で最古削除（Zephyr グルー）
│       ├── wr_fifo_logic.c         # 純粋述語（prune / managed / compare）
│       ├── wr_led_status.c         # ハートビート + 警告優先 LED 状態マシン（グルー）
│       ├── wr_led_pick.c           # 純粋 LED picker（優先度カスケード + 位相）
│       ├── wr_msc_mode.c           # 起動時ボタン長押し MSC モード検出（グルー）
│       └── wr_msc_mode_logic.c     # 純粋判定（threshold / 防御）
├── app_mobile/                     # Phase 6 自前 Flutter アプリ（skeleton）
│   ├── pubspec.yaml                # flutter_blue_plus / permission_handler / path_provider / mocktail
│   ├── lib/
│   │   ├── main.dart
│   │   ├── pages/                  # scan_page / device_page
│   │   └── services/               # wr_uuids / wr_ble_scanner / wr_ble_device / wr_audio_packet / wr_packet_sink
│   └── test/                       # widget + unit tests（scan_page / device_page / wr_audio_packet / wr_packet_sink、計25本）
├── overlay/                        # XIAO Sense 用 devicetree overlay
├── boards/native_sim/              # native_sim テスト用ボード定義
├── tests/
│   ├── firmware/
│   │   ├── data/                   # WAV モックデータ
│   │   ├── sanity/                 # Twister + native_sim サニティテスト（Phase 3）
│   │   ├── wr_chunk/               # 純粋ロジック ztest（Phase 4-6+ + Phase 6）
│   │   ├── wr_fifo/                # 同上 + classify/compare_priority +18 (Phase 6)
│   │   ├── wr_led/                 # LED picker ztest（Phase 4-5+、13本）
│   │   └── wr_msc_mode/            # 同上 + runtime-mode 述語 +13 (Phase 6)
│   └── bsim/
│       ├── wr_smoke/test_scripts/  # 1-device bsim smoke（_env / _compile / run_smoke）
│       └── wr_link/                # 2-device peripheral+central GATT verdict
│           └── test_scripts/       # _env / _compile / run_link（同一 ELF + bs_tests -testid で role 切替）
├── tools/                          # PC-side helpers（Phase 6）
│   ├── decode-dump.py              # BLE notify dump デコーダ（stdlib-only + opuslib opt-in、+12 pytest）
│   ├── power-predict.py            # 電力モデル CLI（§14.2 デフォルト一致、+10 pytest）
│   ├── test_decode_dump.py
│   ├── test_power_predict.py
│   └── README.md
├── CONTRIBUTING.md                 # ブランチ運用 / コミットメッセージ / submodule 不可侵 / レビュアー期待値
├── LICENSE                         # MIT（けんた改修部分、omi 部分の元 MIT と整合）
├── third_party/omi/                # BasedHardware/omi (git submodule、不可侵)
├── docs/
│   ├── wearable-recorder-spec.md   # 正式仕様書
│   ├── phase5-quickstart.md        # Phase 5 実機 bring-up 手順（けんた向け 3 分版）
│   ├── bsim-setup.md               # BabbleSim CI 設計メモ
│   └── phase6-plan-draft.md        # Phase 6 着手用 TODO ドラフト
├── west.yml                        # Zephyr west manifest（NCS v2.7-branch）
└── .github/workflows/
    ├── build.yml                   # firmware-build CI（UF2 + ztest）
    ├── bsim.yml                    # BabbleSim CI（manual trigger、5 stage: wr_smoke + wr_link）
    ├── bsim-nightly.yml            # bsim nightly trigger
    ├── mobile.yml                  # Flutter mobile app CI
    └── tools.yml                   # tools/ pytest CI（Phase 6）
```

## ビルド

### ローカルビルド（west）

```sh
west init -l .
west update --narrow -o=--depth=1
west build -b xiao_ble/nrf52840/sense --sysbuild app
```

UF2 書き込み:
1. XIAO Sense リセットボタンを 2 回素早く押す
2. PC で `XIAO-SENSE` ドライブが認識される
3. `build/zephyr/zephyr.uf2` をドラッグ＆ドロップ

### GitHub Actions の UF2 を使う

main ブランチに push される度に CI が UF2 を生成しているので、以下からダウンロードできる:

1. https://github.com/shkentee/wearable-recorder/actions
2. 最新の成功ビルドを開く
3. Artifacts セクションから `wearable-recorder-uf2` をダウンロード

## ライセンス

omi 部分は元の MIT ライセンスに従う。けんた改修部分は別途明記。
