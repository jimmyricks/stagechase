import Foundation

public enum OSCAddress {
    public static func isValid(_ address: String) -> Bool {
        guard address.first == "/", !address.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return false
        }
        return !address.contains("//") && !address.contains("#") && !address.contains(",")
    }
}

public enum OSCMessage {
    public static func float(address: String, value: Float) throws -> Data {
        guard OSCAddress.isValid(address), value.isFinite else {
            throw OSCError.invalidMessage
        }
        var data = Data()
        appendPaddedString(address, to: &data)
        appendPaddedString(",f", to: &data)
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        return data
    }

    public static func trigger(address: String) throws -> Data {
        guard OSCAddress.isValid(address) else { throw OSCError.invalidMessage }
        var data = Data()
        appendPaddedString(address, to: &data)
        appendPaddedString(",i", to: &data)
        var value = Int32(1).bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        return data
    }

    private static func appendPaddedString(_ string: String, to data: inout Data) {
        data.append(contentsOf: string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
    }
}

public enum OSCError: Error, Equatable {
    case invalidMessage
}
