import Foundation
import LLMClient
import LLMTool

/// Closure-backed `Tool`, for handlers that capture their dependencies — store, providers, HTTP
/// client — rather than receiving them as arguments.
///
/// `execute(with:)` never propagates an error: a throwing handler becomes a tool error the model
/// reads, so one failed asset does not abort the run.
struct MediaTool: Tool {
    let toolName: String
    let toolDescription: String
    let inputSchema: JSONSchema
    private let handler: @Sendable (Data) async throws -> ToolResult

    init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        handler: @escaping @Sendable (Data) async throws -> ToolResult
    ) {
        self.toolName = name
        self.toolDescription = description
        self.inputSchema = inputSchema
        self.handler = handler
    }

    func execute(with argumentsData: Data) async throws -> ToolResult {
        do {
            return try await handler(argumentsData)
        } catch {
            // Hand failures back to the model so it can try another candidate or another tool
            // (falling back to generation, for instance) instead of the run ending here.
            return .error(errorMessage(error))
        }
    }

    private func errorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return String(describing: error)
    }
}

enum ToolArgumentsDecoder {
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}

extension ToolResult {
    /// Encodes a result as JSON with snake_case keys, matching the convention the tool schemas
    /// declare for arguments so the model sees one naming style in both directions.
    static func encodedSnakeCase<T: Encodable>(_ value: T) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return .json(try encoder.encode(value))
    }
}
