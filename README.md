# wearable-recorder

自作ウェアラブル録音デバイスのファームウェア。Seeed XIAO nRF52840 Sense + microSD で起きている間ずっと録音し、後でローカル faster-whisper large-v3 で文字起こしする。

[BasedHardware/omi](https://github.com/BasedHardware/omi) DK1+SPISD ベース、Plan B（常時SD書き込み）、ボタン長押しMSCモード、ハートビート式LED通知に改修。

## ステータス

Phase 1: リポジトリ構築（進行中）

詳細は [docs/wearable-recorder-spec.md](docs/wearable-recorder-spec.md) と
[実装プラン](https://github.com/shkentee/wearable-recorder/blob/main/README.md#) 参照。

## ディレクトリ構成

```
.
├── app/                      # けんた独自コード（Plan B / FIFO / MSC / LED）
│   ├── prj.conf
│   ├── CMakeLists.txt
│   └── src/
├── overlay/                  # XIAO Sense 用 devicetree overlay
├── boards/native_sim/        # native_sim テスト用ボード定義
├── tests/firmware/           # native_sim + WAVモックテスト
├── third_party/omi/          # BasedHardware/omi (git submodule)
├── docs/                     # 仕様書
├── west.yml                  # Zephyr west manifest
└── .github/workflows/        # CI（GitHub Actions）
```

## ビルド

```sh
west init -l .
west update --narrow -o=--depth=1
west build -b xiao_ble/nrf52840/sense --sysbuild app
```

UF2 書き込みは XIAO Sense リセット2回 → ドラッグドロップ。

## ライセンス

omi 部分は元の MIT ライセンスに従う。けんた改修部分は別途明記。
