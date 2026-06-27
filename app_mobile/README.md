# wearable-recorder mobile app

Phase 6 自前ミニマルスマホアプリ。omi 公式 Flutter アプリは大きすぎる
ので、本リポジトリ専用の薄いクライアントを別ツリーで構築する。

## 状態

🚧 **Phase 6 着手スケルトン** — BLE スキャン → 接続 → audioCodec
notify 受信までを最小実装中。Drive 連携 / バックグラウンド常時接続 /
Whisper 連携は後続スプリント。

## 構成

```
app_mobile/
├── lib/
│   ├── main.dart                 # MaterialApp エントリ
│   ├── pages/
│   │   ├── scan_page.dart        # BLE スキャン + デバイスリスト
│   │   └── device_page.dart      # 接続済デバイスの notify 表示
│   └── services/
│       ├── wr_ble_scanner.dart   # FlutterBluePlus ラッパ
│       ├── wr_ble_device.dart    # 単一デバイスの GATT セッション
│       └── wr_uuids.dart         # omi GATT UUID 定義
├── pubspec.yaml
└── README.md
```

## 必要なローカルセットアップ

このスケルトンは `lib/` と `pubspec.yaml` のみ。
プラットフォーム scaffolding (android/, ios/) は **意図的にチェックイン
していない** ので、初回は `flutter create` で生成する:

```bash
cd app_mobile
flutter create --platforms=android,ios --project-name wearable_recorder .
flutter pub get
flutter run -d <device-id>
```

`flutter create` は既存の `pubspec.yaml` / `lib/main.dart` を上書き
**しない**（既に存在する場合）。生成された `.gitignore` は本リポの
.gitignore でカバーされる範囲なので追加で除外しなくてよい。

### AndroidManifest.xml 追記

`android/` は生成物として Git 管理していないため、ローカルで
`flutter create` し直した場合は `android/app/src/main/AndroidManifest.xml`
に以下を追加する。CI の `mobile` workflow でも同じ内容を自動注入している。

`<application>` より前:

```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" />
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT" />
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

`<application>` の中:

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="connectedDevice"
    android:exported="false" />
```

古い `ForegroundTaskService` 名では `flutter_foreground_task` 8.x の
フォアグラウンドサービスが起動せず、バックグラウンド維持通知も出ない。

## 必要 SDK

| ツール | バージョン |
|---|---|
| Flutter | 3.24+ (Dart 3.5+) |
| Android Studio | Hedgehog 以降 |
| Xcode | 15+ (iOS テスト時のみ) |

## 動作確認の流れ

1. wearable-recorder ファーム書き込み済デバイスを起動
2. このアプリで「Scan」ボタンを押す
3. デバイス名 `Omi DK1` (omi 既定) が見えたらタップ → 接続
4. 接続成功で audioCodec characteristic の notify を購読 → パケット数を
   画面表示（実データの保存・デコードは後続）

## 補足: omi 公式アプリとの関係

omi 本体（`third_party/omi/app/`）は会員機能 / バックエンド連携 / 多言語
等で重く、フォークすると追従コストが高い。本リポではそれを参考に
**自前最小実装** を維持し、ファーム側の独自拡張（チャンクファイル
構造、storage GATT 経由の一括取得など）の検証ベンチを兼ねる。
