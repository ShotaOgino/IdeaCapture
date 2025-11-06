# 推奨コマンド

## ビルドとテスト
```bash
# プロジェクトのビルド
xcodebuild -project IdeaCapture.xcodeproj -scheme IdeaCapture -configuration Debug build

# テストの実行
xcodebuild test -project IdeaCapture.xcodeproj -scheme IdeaCapture -destination 'platform=iOS Simulator,name=iPhone 15'

# クリーンビルド
xcodebuild clean -project IdeaCapture.xcodeproj -scheme IdeaCapture
```

## Git操作
```bash
# ステータス確認
git status

# 変更の確認
git diff

# コミット
git add .
git commit -m "メッセージ"

# ログ確認
git log --oneline -10
```

## ファイル操作 (Darwin)
```bash
# ファイル一覧
ls -la

# ディレクトリ内検索
find . -name "*.swift"

# パターン検索
grep -r "pattern" .

# ファイル内容表示
cat filename.swift
```

## プロジェクト固有
```bash
# Xcodeでプロジェクトを開く
open IdeaCapture.xcodeproj

# シミュレータ一覧
xcrun simctl list devices
```