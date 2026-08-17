import Foundation
import OSLog

public enum LogCategory: String, CaseIterable, Sendable {
    case app
    case session
    case input
    case render
    case security
    case channel
}

public enum FarframeLog {
    public static func logger(for category: LogCategory) -> Logger {
        Logger(subsystem: AppEnvironment.bundleIdentifier, category: category.rawValue)
    }

}

public enum DiagnosticRedaction {
    public static func privateValue(_ value: String?) -> String {
        guard let value, !value.isEmpty else {
            return "<none>"
        }
        return "<private>"
    }

    public static func sanitize(_ text: String, sensitiveValues: [String] = []) -> String {
        var result = text
        for value in sensitiveValues where !value.isEmpty {
            result = result.replacingOccurrences(of: value, with: "<private>")
        }

        let patterns = [
            #"(?i)(password|passwd|token|authorization|cookie|username|domain|host(name)?|fingerprint)\s*[:=]\s*[^\s,;]+"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----"#,
            #"/Users/[^/\s]+"#,
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "<private>"
            )
        }
        return result
    }

}

public enum DiagnosticArtifactFinding: String, Equatable, Sendable {
    case secretCanary
    case credentialAssignment
    case authorizationHeader
    case privateKey
    case userHomePath
}

public enum DiagnosticArtifactScanner {
    public static func findings(
        in text: String,
        secretCanaries: [String] = []
    ) -> Set<DiagnosticArtifactFinding> {
        var findings: Set<DiagnosticArtifactFinding> = []
        if secretCanaries.contains(where: { !$0.isEmpty && text.contains($0) }) {
            findings.insert(.secretCanary)
        }
        if text.range(
            of: #"(?i)(password|passwd|token|username|domain|host(name)?|fingerprint)\s*[:=]\s*[^\s,;<>]+"#,
            options: .regularExpression
        ) != nil {
            findings.insert(.credentialAssignment)
        }
        if text.range(of: #"(?i)(authorization\s*[:=]|bearer\s+)"#, options: .regularExpression) != nil {
            findings.insert(.authorizationHeader)
        }
        if text.range(of: #"-----BEGIN [^-]*PRIVATE KEY-----"#, options: .regularExpression) != nil {
            findings.insert(.privateKey)
        }
        if text.range(of: #"/Users/[^/\s]+"#, options: .regularExpression) != nil {
            findings.insert(.userHomePath)
        }
        return findings
    }
}

public enum DiagnosticArtifactError: Error, Equatable, Sendable {
    case unsafeContent(Set<DiagnosticArtifactFinding>)
}

/// Builds deterministic, text-only diagnostic artifacts. Callers may supply
/// raw error or crash summaries, but every value is sanitized and scanned
/// before the artifact can be returned or written to disk.
public enum DiagnosticArtifactBuilder {
    public static func build(
        sections: [String: String],
        sensitiveValues: [String] = []
    ) throws -> Data {
        let text = sections.keys.sorted().map { key in
            let safeKey = DiagnosticRedaction.sanitize(key, sensitiveValues: sensitiveValues)
            let safeValue = DiagnosticRedaction.sanitize(sections[key] ?? "", sensitiveValues: sensitiveValues)
            return "\(safeKey): \(safeValue)"
        }.joined(separator: "\n") + "\n"
        let findings = DiagnosticArtifactScanner.findings(
            in: text,
            secretCanaries: sensitiveValues
        )
        guard findings.isEmpty else {
            throw DiagnosticArtifactError.unsafeContent(findings)
        }
        return Data(text.utf8)
    }
}
