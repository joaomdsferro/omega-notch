import Foundation

/// Any JSON value. The config is kept in this form and sent back whole, so
/// fields this shell does not know about survive a round trip through it.
public enum JSONValue: Codable, Equatable, Sendable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else {
      self = .object(try container.decode([String: JSONValue].self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case .bool(let value): try container.encode(value)
    case .number(let value):
      // Whole numbers go out as integers: the engine reads some fields as u32.
      if value.rounded() == value, abs(value) < 1e15 {
        try container.encode(Int64(value))
      } else {
        try container.encode(value)
      }
    case .string(let value): try container.encode(value)
    case .array(let value): try container.encode(value)
    case .object(let value): try container.encode(value)
    }
  }

  public subscript(key: String) -> JSONValue? {
    get {
      if case .object(let object) = self { return object[key] }
      return nil
    }
    set {
      guard case .object(var object) = self else { return }
      object[key] = newValue
      self = .object(object)
    }
  }

  public var string: String? {
    if case .string(let value) = self { return value }
    return nil
  }

  public var double: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var bool: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }
}
