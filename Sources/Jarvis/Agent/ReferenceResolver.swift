import Foundation

public final class ReferenceResolver: @unchecked Sendable {
    public static let shared = ReferenceResolver()

    public init() {}

    public func resolveReferences(_ text: String, context: [String: String]) -> String {
        if context.isEmpty || (!text.contains("$") && !text.contains("{")) {
            return text
        }

        var result = text
        for (key, val) in context {
            let placeholder1 = "${\(key)}"
            let placeholder2 = "$\(key)"
            if result.contains(placeholder1) {
                result = result.replacingOccurrences(of: placeholder1, with: val)
            }
            if result.contains(placeholder2) {
                result = result.replacingOccurrences(of: placeholder2, with: val)
            }
        }

        return result
    }
}