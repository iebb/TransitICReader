import Foundation

struct SavedCardField: Codable, Hashable, Identifiable {
    let id: String
    let title: String
    let value: String

    init(title: String, value: String) {
        self.id = "\(title)|\(value)"
        self.title = title
        self.value = value
    }

    init(_ field: ResultField) {
        self.init(title: field.title, value: field.value)
    }
}

