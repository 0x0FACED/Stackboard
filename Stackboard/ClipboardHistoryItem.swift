import Foundation

enum ClipboardContentKind: String {
    case text
    case image
    case file
}

struct ClipboardHistoryItem: Identifiable {
    let id: UUID
    let createdAt: Date
    let kind: ClipboardContentKind
    let textValue: String?
    let imageRelativePath: String?
    let filePath: String?
    let contentHash: String

    var fileExists: Bool {
        guard let filePath else {
            return false
        }

        return FileManager.default.fileExists(atPath: filePath)
    }

    var kindTitle: String {
        switch kind {
        case .text:
            return "Text"
        case .image:
            return "Image"
        case .file:
            return "File"
        }
    }

    var menuTitle: String {
        switch kind {
        case .text:
            let text = (textValue ?? "")
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? "Empty text clip" : String(text.prefix(40))
        case .image:
            return "Screenshot • \(Self.timeFormatter.string(from: createdAt))"
        case .file:
            guard let filePath else {
                return "Missing file reference"
            }
            let url = URL(fileURLWithPath: filePath)
            return url.lastPathComponent.isEmpty ? filePath : url.lastPathComponent
        }
    }

    var detailText: String {
        switch kind {
        case .text:
            return Self.dateFormatter.string(from: createdAt)
        case .image:
            return "Image • \(Self.dateFormatter.string(from: createdAt))"
        case .file:
            let prefix = fileExists ? "File" : "Missing file"
            return "\(prefix) • \(Self.dateFormatter.string(from: createdAt))"
        }
    }

    var searchableText: String {
        switch kind {
        case .text:
            return [textValue, Self.dateFormatter.string(from: createdAt)]
                .compactMap { $0 }
                .joined(separator: " ")
        case .image:
            return "screenshot image \(Self.dateFormatter.string(from: createdAt))"
        case .file:
            return [
                filePath,
                URL(fileURLWithPath: filePath ?? "").lastPathComponent,
                fileExists ? "file" : "missing deleted file",
                Self.dateFormatter.string(from: createdAt)
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
