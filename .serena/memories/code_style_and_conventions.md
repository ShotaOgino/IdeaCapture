# コードスタイルと規約

## 命名規約
- **クラス/構造体**: PascalCase (例: `RecorderViewModel`, `IdeaCaptureApp`)
- **プロパティ/メソッド**: camelCase (例: `isRecording`, `startRecording()`)
- **定数**: camelCase
- **プライベートプロパティ**: camelCase (アンダースコアプレフィックスなし)

## コード構造
- **ViewModelパターン**: `@ObservableObject`を使用したMVVMアーキテクチャ
- **プロパティ**: `@Published`を使用してビューとの同期
- **非同期処理**: `async/await`パターンとMainActorの使用

## Swift特有の規約
- `@MainActor`を使用してUIスレッドでの実行を保証
- `private`修飾子で内部実装をカプセル化
- Optional型の安全な扱い (`if let`, `guard let`)
- UserDefaultsでの永続化にApp Groupsを使用

## ファイル構成
- 各ビューとViewModelは個別ファイルに分離
- 関連するモデル構造体は同じファイル内に定義可能 (例: `TranscriptEntry`)

## エラーハンドリング
- `do-catch`ブロックでエラーを適切にキャッチ
- `print()`でデバッグ情報を出力