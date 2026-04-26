# wearable-recorder

![build](https://github.com/shkentee/wearable-recorder/actions/workflows/build.yml/badge.svg)

自作ウェアラブル録音デバイスのファームウェア。Seeed XIAO nRF52840 Sense + microSD で起きている間ずっと録音し、後でローカル faster-whisper large-v3 で文字起こしする。

[BasedHardware/omi](https://github.com/BasedHardware/omi) DK1+SPISD ベース、Plan B（常時SD書き込み）、ボタン長押しMSCモード、ハートビート式LED通知に改修。

## ステータス

**Phase 4 完了 / Phase 5 待ち**

| Phase | 内容 | 状態 |
|---|---|---|
| Phase 1 | リポジトリ構築・仕様書（17決定事項）反映 | ✅ |
| Phase 2 | GitHub Actions ビルド CI（NCS v2.7-branch、UF2 アーティファクト）| ✅ |
| Phase 3 | Twister + native_sim サニティテスト（FIFO 閾値ユニットテスト）| ✅ |
| Phase 4 | Plan B / チャンク / FIFO / MSC / LED（5サブタスク MVP）| ✅ |
| Phase 5 | 実機書き込み・電力測定（PPK2）| ⏳ |
| Phase 6 | 自前ミニマルスマホアプリ + チャンク命名本格化 | ⏳ |

詳細は [docs/wearable-recorder-spec.md](docs/wearable-recorder-spec.md) §22、Phase 6 着手準備は [docs/phase6-plan-draft.md](docs/phase6-plan-draft.md) 参照。

### Phase 4 完了内容

- **4-1 Plan B**: omi `transport.c::pusher()` を ファンアウト構造に refactor（`app/patches/0001-plan-b-fanout-tx-queue.patch`）。BLE と SD 両方に同じ TX データを書き込み
- **4-2 チャンクローテーション (MVP)**: 10分タイマー → `chunk_NNNNN.opus` リネーム → 新 `a01.txt` 作成（連番命名のみ。UNIX_epoch / boot ID / サイズ閾値は Phase 6）
- **4-3 FIFO 自動削除**: 1分ごとに `fs_statvfs`、空き<10% で最古 chunk を unlink（録音中ファイルは除外）
- **4-4 USB MSC (MVP)**: 起動時 D5 長押し検出 → `wr_msc_mode_is_active()` フラグ。runtime mode-switch は Phase 5 実機検証後
- **4-5 LED 状態マシン**: 100ms tick で警告優先順位 + ハートビート。バッテリー ADC は Phase 5 でフック予定

### Phase 5 / Phase 6 未着手項目

- **Phase 5**: 実機書き込み（XIAO Sense UF2）、PPK2 電力測定、バッテリー ADC、MSC runtime 切替、Plan B 実機ジッター測定
- **Phase 6**: 自前ミニマルスマホアプリ（Flutter or React Native）、チャンク命名本格化（`<UNIX_epoch>.opus` / `unsynced_<bootid>_<seq>.opus`）、サイズ閾値ローテーション

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
│   └── src/
│       ├── wr_chunk.c              # 10分チャンクローテーション
│       ├── wr_fifo.c               # 空き10%以下で最古削除
│       ├── wr_led_status.c         # ハートビート + 警告優先 LED 状態マシン
│       └── wr_msc_mode.c           # 起動時ボタン長押し MSC モード検出
├── overlay/                        # XIAO Sense 用 devicetree overlay
├── boards/native_sim/              # native_sim テスト用ボード定義
├── tests/firmware/
│   ├── data/                       # WAV モックデータ
│   └── sanity/                     # Twister + native_sim サニティテスト
├── third_party/omi/                # BasedHardware/omi (git submodule、不可侵)
├── docs/
│   ├── wearable-recorder-spec.md   # 正式仕様書
│   └── phase6-plan-draft.md        # Phase 6 着手用 TODO ドラフト
├── west.yml                        # Zephyr west manifest（NCS v2.7-branch）
└── .github/workflows/              # CI（GitHub Actions）
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
