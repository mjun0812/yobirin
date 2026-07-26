import Foundation

/// スケジュールされた処理を取り消すためのハンドル。
protocol Cancellable {
    func cancel()
}

/// タイムアウトタイマーのスケジューリングを抽象化する (design.md AppLifecycle, Requirements 5.1-5.4)。
///
/// テストでは手動発火するモックへ差し替え、実装は `DispatchQueueScheduler` を使う。
typealias Scheduler = (TimeInterval, @escaping () -> Void) -> Cancellable

extension DispatchWorkItem: Cancellable {}

/// 実スケジューラ。`DispatchQueue.asyncAfter` を使い、ポーリングは行わない (design.md 設計上の決定)。
enum DispatchQueueScheduler {
    static func schedule(after seconds: TimeInterval, _ block: @escaping () -> Void) -> Cancellable {
        let workItem = DispatchWorkItem(block: block)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: workItem)
        return workItem
    }
}
