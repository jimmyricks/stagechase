import Foundation

public struct ImportedAdvancedOutput: Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var slices: [StageSlice]
    public var warnings: [String]
}

public enum AdvancedOutputImportError: Error, Equatable, LocalizedError {
    case unreadableXML
    case noSlices

    public var errorDescription: String? {
        switch self {
        case .unreadableXML: "This file is not readable XML. Select an Arena Advanced Output XML preset."
        case .noSlices: "No supported screen slices were found. This preset structure may not be supported yet."
        }
    }
}

public enum AdvancedOutputImporter {
    public static func importData(_ data: Data) throws -> ImportedAdvancedOutput {
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw AdvancedOutputImportError.unreadableXML
        }

        let allNodes = root.descendants(includeSelf: true)
        let screenNameBySlice = screenNames(in: allNodes)
        let defaultScreenName = allNodes.first { normalized($0.name) == "screen" }
            .map { $0.displayName(fallback: "Screen") } ?? "Screen"
        let compositionSize = allNodes.first { normalized($0.name) == "currentcompositiontexturesize" }
            .flatMap { node -> (Double, Double)? in
                guard let width = node.number("width"), let height = node.number("height"),
                      width > 0, height > 0 else { return nil }
                return (width, height)
            }
        let candidates = allNodes.filter { normalized($0.name) == "slice" }
        var slices: [StageSlice] = []
        var warnings: [String] = []
        var usedIDs = Set<String>()

        for (index, node) in candidates.enumerated() {
            let points = geometry(for: node)
            guard points.count >= 3 else {
                warnings.append("Skipped slice \(node.displayName(fallback: "Slice \(index + 1)")) because no supported polygon geometry was found.")
                continue
            }
            let rawID = node.attribute("uniqueId") ?? node.attribute("id") ?? "imported-\(index + 1)"
            let id = usedIDs.insert(rawID).inserted ? rawID : "\(rawID)-\(index + 1)"
            let name = node.displayName(fallback: "Slice \(index + 1)")
            slices.append(StageSlice(
                id: id,
                name: name,
                screenName: screenNameBySlice[ObjectIdentifier(node)] ?? defaultScreenName,
                points: points
            ))
        }

        guard !slices.isEmpty else { throw AdvancedOutputImportError.noSlices }
        let points = slices.flatMap(\.points)
        let normalizedGeometry = points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
        if !normalizedGeometry {
            let width = compositionSize?.0 ?? max((points.map(\.x).max() ?? 1) - (points.map(\.x).min() ?? 0), 1)
            let height = compositionSize?.1 ?? max((points.map(\.y).max() ?? 1) - (points.map(\.y).min() ?? 0), 1)
            if compositionSize != nil {
                slices = slices.map { slice in
                    var result = slice
                    result.points = slice.points.map { StagePoint(x: $0.x / width, y: $0.y / height) }
                    return result
                }
            } else {
                let minX = points.map(\.x).min() ?? 0
                let minY = points.map(\.y).min() ?? 0
                slices = slices.map { slice in
                    var result = slice
                    result.points = slice.points.map {
                        StagePoint(x: ($0.x - minX) / width, y: ($0.y - minY) / height)
                    }
                    return result
                }
            }
            return ImportedAdvancedOutput(canvasWidth: width, canvasHeight: height, slices: slices, warnings: warnings)
        }
        return ImportedAdvancedOutput(
            canvasWidth: compositionSize?.0 ?? 1920,
            canvasHeight: compositionSize?.1 ?? 1080,
            slices: slices,
            warnings: warnings
        )
    }

    private static func geometry(for node: XMLTreeNode) -> [StagePoint] {
        if let inputRect = node.children.first(where: { normalized($0.name) == "inputrect" }) {
            let inputPoints = inputRect.children.compactMap { child -> StagePoint? in
                guard normalized(child.name) == "v",
                      let x = child.number("x"), let y = child.number("y") else { return nil }
                return StagePoint(x: x, y: y)
            }
            if inputPoints.count >= 3 { return inputPoints }
        }

        let descendants = node.descendants()
        let points = descendants.compactMap { child -> StagePoint? in
            guard let x = child.number("x"), let y = child.number("y") else { return nil }
            let tag = normalized(child.name)
            guard tag.contains("point") || tag.contains("vertex") || tag.contains("corner") || tag.contains("control") else {
                return nil
            }
            return StagePoint(x: x, y: y)
        }
        if points.count >= 3 { return points }

        guard let x = node.number("x"), let y = node.number("y"),
              let width = node.number("width") ?? node.number("w"),
              let height = node.number("height") ?? node.number("h"),
              width > 0, height > 0 else {
            return []
        }
        return [
            StagePoint(x: x, y: y),
            StagePoint(x: x + width, y: y),
            StagePoint(x: x + width, y: y + height),
            StagePoint(x: x, y: y + height)
        ]
    }

    private static func screenNames(in nodes: [XMLTreeNode]) -> [ObjectIdentifier: String] {
        var result: [ObjectIdentifier: String] = [:]
        for screen in nodes where normalized(screen.name) == "screen" {
            let name = screen.displayName(fallback: "Screen")
            for slice in screen.descendants() where normalized(slice.name) == "slice" {
                result[ObjectIdentifier(slice)] = name
            }
        }
        return result
    }

    private static func normalized(_ value: String) -> String {
        value.lowercased().filter(\.isLetter)
    }
}

private final class XMLTreeNode {
    let name: String
    let attributes: [String: String]
    weak var parent: XMLTreeNode?
    var children: [XMLTreeNode] = []
    var text = ""

    init(name: String, attributes: [String: String], parent: XMLTreeNode?) {
        self.name = name
        self.attributes = attributes
        self.parent = parent
    }

    func descendants(includeSelf: Bool = false) -> [XMLTreeNode] {
        (includeSelf ? [self] : []) + children.flatMap { [$0] + $0.descendants() }
    }

    func attribute(_ name: String) -> String? {
        attributes.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    func number(_ key: String) -> Double? {
        let raw = attribute(key) ?? children.first(where: { $0.name.caseInsensitiveCompare(key) == .orderedSame })?.text
        return raw.flatMap(Double.init)
    }

    func displayName(fallback: String) -> String {
        if let name = attribute("name"), !name.isEmpty { return name }
        if let value = attribute("value"), !value.isEmpty { return value }
        if let parameter = descendants().first(where: {
            $0.name.caseInsensitiveCompare("Param") == .orderedSame &&
            ($0.attribute("name")?.caseInsensitiveCompare("Name") == .orderedSame)
        }), let value = parameter.attribute("value"), !value.isEmpty {
            return value
        }
        return fallback
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLTreeNode?
    private var current: XMLTreeNode?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = XMLTreeNode(name: qName ?? elementName, attributes: attributeDict, parent: current)
        if let current {
            current.children.append(node)
        } else {
            root = node
        }
        current = node
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        current?.text += string.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        current = current?.parent
    }
}
