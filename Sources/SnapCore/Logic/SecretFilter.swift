import Foundation

/// Hides likely secrets in OCR text before it leaves the history folder (Recall design 7.3). Best
/// effort: an oddly formatted secret can still get through, so the exclude list and the search
/// switch are the backstops.
public enum SecretFilter {
    public static let replacement = "[hidden]"

    static let prefixes = [
        "sk_live_", "sk_test_", "rk_live_", "pk_live_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-",
        "AKIA", "ASIA", "AIza", "sk-ant-",
    ]
    /// Characters that end a token. `=` splits too, so `KEY=secret` keeps its name.
    static let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`,;:()[]{}<>="))
    static let keyAlphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-+/=")

    public static func redact(_ lines: [String]) -> [String] {
        var inKeyBlock = false
        return lines.map { line in
            if line.contains("-----BEGIN"), line.contains("PRIVATE KEY") { inKeyBlock = true }
            if inKeyBlock {
                if line.contains("-----END") { inKeyBlock = false }
                return replacement
            }
            return redactLine(line)
        }
    }

    static func redactLine(_ line: String) -> String {
        var result = ""
        var token = ""
        func flush() {
            result += isSecret(token) ? replacement : token
            token = ""
        }
        for character in line {
            if character.unicodeScalars.allSatisfy(separators.contains) {
                flush()
                result.append(character)
            } else {
                token.append(character)
            }
        }
        flush()
        return result
    }

    static func isSecret(_ token: String) -> Bool {
        guard token.count >= 8 else { return false }
        for prefix in prefixes where token.hasPrefix(prefix) && token.count >= prefix.count + 8 { return true }
        if token.hasPrefix("sk-"), token.count - 3 >= 20 { return true }
        if isJWT(token) { return true }
        guard token.unicodeScalars.allSatisfy(keyAlphabet.contains) else { return false }
        let entropy = shannonEntropy(token)
        if token.count >= 32 { return entropy > 4.0 }
        if token.count >= 20 {
            let hasUpper = token.contains(where: \.isUppercase)
            let hasLower = token.contains(where: \.isLowercase)
            let hasDigit = token.contains(where: \.isNumber)
            return hasUpper && hasLower && hasDigit && entropy > 3.5
        }
        return false
    }

    static func isJWT(_ token: String) -> Bool {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, token.hasPrefix("eyJ") else { return false }
        let alphabet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")
        return parts.allSatisfy { !$0.isEmpty && $0.unicodeScalars.allSatisfy(alphabet.contains) }
    }

    static func shannonEntropy(_ text: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in text { counts[character, default: 0] += 1 }
        let total = Double(text.count)
        return counts.values.reduce(0) { sum, count in
            let share = Double(count) / total
            return sum - share * log2(share)
        }
    }
}
