import Foundation

/// One Recall entry file (Recall design 6 and 13): what Shelf searches for one screenshot.
public struct RecallEntry: Codable, Sendable, Equatable {
    public struct Segment: Codable, Sendable, Equatable {
        public var text: String

        public init(text: String) {
            self.text = text
        }
    }

    public static let maxTextLength = 120

    public var schema = 1
    public var app = "snap"
    public var id: String
    public var kind = "screenshot"
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    public var language: String?
    public var preview: String?
    public var context: [String: String]
    public var segments: [Segment]

    enum CodingKeys: String, CodingKey {
        case schema, app, id, kind, title, language, preview, context, segments
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    public init(
        id: String, title: String, createdAt: Date, updatedAt: Date, language: String? = nil, preview: String? = nil,
        context: [String: String] = [:], segments: [Segment]
    ) {
        self.id = id
        self.title = String(title.prefix(Self.maxTextLength))
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.language = language
        self.preview = preview
        self.context = context.mapValues { String($0.prefix(Self.maxTextLength)) }
        self.segments = segments
    }
}
