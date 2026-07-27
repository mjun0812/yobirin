# Product Overview

## Product

**yobirin** (呼び鈴) — macOS向けの通知CLI。鳴らして応答を待つ。

通知を1件出し、ユーザーがクリックしたか・却下したか・どのアクションを押したか・何を入力したかを、構造化データ (JSON) で同期的に返す。

## Why it exists

「通知を出して、その反応を捕捉できるCLI」というニッチに、現役でまともな選択肢が存在しない。

- [vjeantet/alerter](https://github.com/vjeantet/alerter): 機能面では本家だが、却下検知のためのポーリング実装にメモリリークがある (実測: 48分で1.8GB、CPU 11%)。修正PR #65は4ヶ月未マージ。非推奨の `NSUserNotification` に依存し、アイコン差し替え機能は `com.apple.Terminal` へのなりすましで成立している。
- [julienXX/terminal-notifier](https://github.com/julienXX/terminal-notifier): 最終release 2017年。反応の捕捉ができない (fire-and-forget)。
- [variadico/noti](https://github.com/variadico/noti) / [dschep/ntfy](https://github.com/dschep/ntfy): コマンド完了通知が目的。反応の捕捉は非目標。
- [777genius/claude-notifications-go](https://github.com/777genius/claude-notifications-go): Claude Code plugin機構専用。汎用CLIとして切り出されていない。

yobirinは**モダンなUN APIで、通知への反応を同期的に構造化データで返す汎用CLI**という空席を埋める。

## Target Users

- 通知の反応をシェルスクリプトやhookから扱いたい開発者
- coding agent (Claude Code / Codex 等) の通知hookを組んでいる人

## Core Value

1. **正確な却下検知**: `customDismissAction` のコールバックで、バナーを閉じた瞬間を検知する。alerterのポーリング方式では、バナーを閉じても通知センターから消えるまで検知できない。
2. **リークしない**: ポーリングを使わないため、通知を放置してもメモリもCPUも消費しない。
3. **なりすまさない**: 自分の名義で通知を出す。ユーザーがシステム設定で独立して制御できる。
4. **将来性**: 現行の公開APIのみを使い、私用APIハックに依存しない。
5. **1バイナリで完結する導入**: リリースの実行ファイル1つで `yobirin install` するだけ (ツールチェーン不要)。用途別アイコンは `install --profile <name> --icon <path>` で派生バンドルを作り、`--profile` で選択、`list` で一覧できる。

## Non-goals

- alerterとのCLI・JSON出力互換
- 通知ごとの任意アイコン指定 (macOSに実現手段が存在しない)
- Linux / Windows対応
- 常駐デーモン化

## Origin

作者のdotfilesで、Claude Code / Codexの通知hookが使っているalerterのメモリリークが直接の動機。
既存の通知ルーター (`notify.sh`) のバックエンドを差し替える部品として設計されているが、ツール自体はdotfilesの事情を知らない汎用CLIとして独立させる。
