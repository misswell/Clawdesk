import Foundation

/// Best-effort, high-confidence display redaction for text that is about to
/// leave the desktop for a remote approval/notification channel (Telegram,
/// Feishu, Slack). A direct port of upstream `secret-redact.js`: it redacts
/// shapes that are almost always secrets — provider token prefixes,
/// Authorization headers, secret-named key=value pairs, Slack webhook URLs,
/// bot tokens and long numeric IDs — and deliberately does not chase
/// completeness, because an over-eager blacklist mis-redacts ordinary prose.
public enum SecretRedactor {
    private static let patterns: [(regex: NSRegularExpression, template: String)] = {
        func regex(_ pattern: String) -> NSRegularExpression {
            // Every pattern below is a verbatim upstream expression.
            try! NSRegularExpression(pattern: pattern, options: [])
        }
        return [
            // Telegram bot token (digits:base64-ish).
            (regex(#"\b\d+:[A-Za-z0-9_-]{20,}\b"#), "<redacted:telegram-token>"),
            // Authorization / Proxy-Authorization header: scheme + credential.
            (regex(#"\b(?:proxy-)?authorization\b\s*[:=]\s*[^\r\n]*"#, ), "authorization=<redacted>"),
            // A Slack Incoming Webhook URL is itself the credential.
            (regex(#"\bhttps?://hooks\.slack\.com(?::\d{1,5})?/[^\s<>"']+"#), "<redacted:slack-webhook>"),
            // High-confidence provider token shapes (explicit prefixes only).
            (regex(#"\bsk-(?:proj-|ant-)?[A-Za-z0-9_-]{12,}\b"#), "<redacted:token>"),
            (regex(#"\bxox[abprs]-[A-Za-z0-9-]{10,}\b"#), "<redacted:token>"),
            (regex(#"\b(?:github_pat_[A-Za-z0-9_]{20,}|gh[pousr]_[A-Za-z0-9]{20,})\b"#), "<redacted:token>"),
            (regex(#"\bglpat-[A-Za-z0-9_-]{16,}\b"#), "<redacted:token>"),
            (regex(#"\bAIza[A-Za-z0-9_-]{20,}\b"#), "<redacted:token>"),
            (regex(#"\bAKIA[A-Z0-9]{12,}\b"#), "<redacted:token>"),
            // Secret-named key with a value: KEY=val, key: val, "key":"val".
            (
                regex(#"\b(api[_-]?key|access[_-]?key|secret[_-]?access[_-]?key|secret[_-]?key|access[_-]?token|refresh[_-]?token|auth[_-]?token|api[_-]?token|private[_-]?key|client[_-]?secret|password|passwd|secret|token|cookie)"?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s"',;}{]+)"#),
                "$1=<redacted>"
            ),
            (
                regex(#"\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*_(?:API_KEY|ACCESS_KEY|SECRET_ACCESS_KEY|SECRET_KEY|ACCESS_TOKEN|REFRESH_TOKEN|AUTH_TOKEN|API_TOKEN|TOKEN|SECRET|PASSWORD|PASSWD|PRIVATE_KEY|CLIENT_SECRET|COOKIE|CREDENTIALS?))"?\s*[:=]\s*(?:"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|[^\s"',;}{]+)"#),
                "$1=<redacted>"
            ),
            // General long numeric IDs.
            (regex(#"\b(?:telegram:)?-?\d{7,}(?::\d+){0,2}\b"#), "<redacted:id>"),
        ]
    }()

    public static func redact(_ value: String) -> String {
        var text = value
        for pattern in patterns {
            let range = NSRange(text.startIndex..., in: text)
            text = pattern.regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: pattern.template
            )
        }
        return text
    }
}
