import Foundation
import LLMClient
import LLMTool

/// クロージャベースの Tool 実装。DI が重いツール（ストア・プロバイダー注入）向け。
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
            // 失敗は LLM へ返して別候補・別手段（生成へのフォールバック等）を促す
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
    /// snake_case キーで JSON 結果を作成（ツール引数のキー規約と揃える）。
    static func encodedSnakeCase<T: Encodable>(_ value: T) throws -> ToolResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return .json(try encoder.encode(value))
    }
}
