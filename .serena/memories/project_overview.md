# IdeaCapture プロジェクト概要

## プロジェクトの目的
IdeaCaptureは音声認識機能を持つiOS/macOSアプリケーションです。ユーザーが音声を録音し、リアルタイムで文字起こしを行い、セッション履歴を管理できます。Siri連携とWidgetExtension機能も備えています。

## 技術スタック
- **言語**: Swift 5.0
- **プラットフォーム**: iOS/macOS (Darwin)
- **最小デプロイメントターゲット**: iOS 16.0
- **フレームワーク**: 
  - SwiftUI (UI)
  - Speech Framework (音声認識)
  - AVFoundation (オーディオエンジン)
  - App Intents (Siri連携)
  - WidgetKit (Widget Extension)
- **ビルドシステム**: Xcode 16.4, Swift Package Manager

## プロジェクト構造
```
IdeaCapture/
├── IdeaCapture.xcodeproj/          # Xcodeプロジェクトファイル
├── IdeaCapture/                    # メインアプリケーション
│   ├── IdeaCaptureApp.swift        # アプリエントリーポイント
│   ├── ContentView.swift           # メインビュー
│   ├── RecorderViewModel.swift     # 録音・文字起こしのコアロジック
│   ├── HistoryView.swift           # 履歴表示
│   ├── SessionEndView.swift        # セッション終了画面
│   ├── WaveformView.swift          # 波形表示
│   ├── StartRecordingIntent.swift  # Siri連携インテント
│   └── Assets.xcassets/            # アセット
├── IdeaCaptureWidget/              # Widget Extension
├── IdeaCaptureTests/               # ユニットテスト
└── IdeaCaptureUITests/             # UIテスト
```

## 主要コンポーネント
- **IdeaCaptureApp**: @main エントリーポイント
- **RecorderViewModel**: 音声録音、認識、履歴管理のメインロジック
- **ContentView**: メインUIビュー
- **HistoryView**: 文字起こし履歴の表示
- **StartRecordingIntent**: Siriからの録音開始インテント