import Foundation

/// タイムアウト指定を秒数へ換算する唯一の規則 (design.md TimeoutDuration、
/// Requirements 4.1〜4.5, 14.3, 14.4)。
///
/// `NotifyCommand` の引数変換と `PsCommand` のargv解釈が共有する。Foundationのみに依存し
/// 通知APIの型に触れないため、バンドル不要のコマンド (`ps`) からも安全に呼べる (Requirement 14.9)。
enum TimeoutDuration {
    private static let unitSeconds: [Character: Double] = ["h": 3600, "m": 60, "s": 1]

    /// 受理する文法:
    /// - `bare` := 正の10進数 (小数可)。例: `300`, `0.5` — 従来の秒指定と同一 (Requirement 4.1)
    /// - `united` := (正の整数 + `h`|`m`|`s`) の1回以上の連結。例: `5m`, `90s`, `1h30m`
    ///
    /// 単位の重複 (`5m5m`) と順序入れ替え (`30m1h`) は合計値が一意に定まるため受理する。
    /// いずれの文法にも一致しない、または換算結果が正の有限値でない場合は `nil` を返す
    /// (Requirements 4.4, 4.5)。エラー文言の生成は呼び出し側の責務とする。
    static func seconds(from value: String) -> Double? {
        guard let total = Double(value) ?? unitedSeconds(value), total.isFinite, total > 0 else {
            return nil
        }
        return total
    }

    /// 単位付き表記の換算。桁の累積は `Double` で行う。`Int` で累積すると桁数の多い入力で
    /// オーバーフローし、Swiftでは実行時トラップになる。
    private static func unitedSeconds(_ value: String) -> Double? {
        var total: Double = 0
        var pendingDigits: Double?

        for character in value {
            if character.isASCII, character.isNumber, let digit = character.wholeNumberValue {
                pendingDigits = (pendingDigits ?? 0) * 10 + Double(digit)
                continue
            }
            guard let unit = unitSeconds[character], let digits = pendingDigits else {
                return nil
            }
            total += digits * unit
            pendingDigits = nil
        }

        // 末尾に単位の付かない数字が残る指定 (`5m30`) は受理しない。
        guard pendingDigits == nil else { return nil }
        return total
    }
}
