import Foundation

public struct StagePoint: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct StageSlice: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var screenName: String
    public var points: [StagePoint]

    public init(id: String, name: String, screenName: String = "Screen", points: [StagePoint]) {
        self.id = id
        self.name = name
        self.screenName = screenName
        self.points = points
    }
}

public struct ChaseView: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var visibleSliceIDs: Set<String>

    public init(id: String = UUID().uuidString, name: String, visibleSliceIDs: Set<String>) {
        self.id = id
        self.name = name
        self.visibleSliceIDs = visibleSliceIDs
    }
}

public struct ChaseStep: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var enabledSliceIDs: Set<String>

    public init(id: String = UUID().uuidString, enabledSliceIDs: Set<String> = []) {
        self.id = id
        self.enabledSliceIDs = enabledSliceIDs
    }
}

public enum ChaseDirection: String, Codable, CaseIterable, Sendable {
    case forward
    case reverse
    case pingPong
    case random

    public var title: String {
        switch self {
        case .forward: "Forward"
        case .reverse: "Reverse"
        case .pingPong: "Ping-pong"
        case .random: "Random"
        }
    }
}

public enum SliceScaling: String, Codable, CaseIterable, Sendable {
    case fill
    case mask
    case stretch

    public var title: String {
        switch self {
        case .fill: "Fill"
        case .mask: "Mask"
        case .stretch: "Stretch"
        }
    }
}

public struct ChaseSequence: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var steps: [ChaseStep]
    public var direction: ChaseDirection
    public var stepDuration: Double
    public var scaling: SliceScaling
    public var echoes: Int

    public init(
        id: String = UUID().uuidString,
        name: String,
        steps: [ChaseStep],
        direction: ChaseDirection = .forward,
        stepDuration: Double = 0.45,
        scaling: SliceScaling = .fill,
        echoes: Int = 0
    ) {
        self.id = id
        self.name = name
        self.steps = steps.isEmpty ? [ChaseStep()] : steps
        self.direction = direction
        self.stepDuration = min(max(stepDuration, 0.025), 60)
        self.scaling = scaling
        self.echoes = min(max(echoes, 0), 32)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case steps
        case direction
        case stepDuration
        case scaling
        case echoes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        steps = try values.decode([ChaseStep].self, forKey: .steps)
        direction = try values.decodeIfPresent(ChaseDirection.self, forKey: .direction) ?? .forward
        stepDuration = try values.decodeIfPresent(Double.self, forKey: .stepDuration) ?? 0.45
        scaling = try values.decodeIfPresent(SliceScaling.self, forKey: .scaling) ?? .fill
        echoes = try values.decodeIfPresent(Int.self, forKey: .echoes) ?? 0
    }
}

public enum WidgetKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case fader
    case toggle
    case trigger
    case strobe

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .fader: "Fader"
        case .toggle: "Toggle"
        case .trigger: "Trigger"
        case .strobe: "Strobe"
        }
    }
}

public enum WidgetWidth: String, Codable, CaseIterable, Sendable {
    case compact
    case wide
}

public struct OSCWidget: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: WidgetKind
    public var address: String
    public var minimum: Float
    public var maximum: Float
    public var restingValue: Float
    public var strobeRate: Double
    public var order: Int
    public var width: WidgetWidth

    public init(
        id: String = UUID().uuidString,
        title: String,
        kind: WidgetKind,
        address: String,
        minimum: Float = 0,
        maximum: Float = 1,
        restingValue: Float = 0,
        strobeRate: Double = 8,
        order: Int = 0,
        width: WidgetWidth = .compact
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.address = address
        self.minimum = minimum
        self.maximum = maximum
        self.restingValue = restingValue
        self.strobeRate = min(max(strobeRate, 1), 20)
        self.order = order
        self.width = width
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case kind
        case address
        case minimum
        case maximum
        case restingValue
        case strobeRate
        case order
        case width
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decode(WidgetKind.self, forKey: .kind)
        address = try values.decode(String.self, forKey: .address)
        minimum = try values.decodeIfPresent(Float.self, forKey: .minimum) ?? 0
        maximum = try values.decodeIfPresent(Float.self, forKey: .maximum) ?? 1
        restingValue = try values.decodeIfPresent(Float.self, forKey: .restingValue) ?? 0
        strobeRate = try values.decodeIfPresent(Double.self, forKey: .strobeRate) ?? 8
        order = try values.decodeIfPresent(Int.self, forKey: .order) ?? 0
        width = try values.decodeIfPresent(WidgetWidth.self, forKey: .width) ?? .compact
    }
}

public struct StageChaseProject: Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var title: String
    public var canvasWidth: Double
    public var canvasHeight: Double
    public var slices: [StageSlice]
    public var views: [ChaseView]
    public var sequences: [ChaseSequence]
    public var widgets: [OSCWidget]

    public init(
        schemaVersion: Int = currentSchemaVersion,
        title: String,
        canvasWidth: Double,
        canvasHeight: Double,
        slices: [StageSlice],
        views: [ChaseView],
        sequences: [ChaseSequence],
        widgets: [OSCWidget]
    ) {
        self.schemaVersion = schemaVersion
        self.title = title
        self.canvasWidth = max(canvasWidth, 1)
        self.canvasHeight = max(canvasHeight, 1)
        self.slices = slices
        self.views = views
        self.sequences = sequences.isEmpty ? [ChaseSequence(name: "Sequence 1", steps: [ChaseStep()])] : sequences
        self.widgets = widgets.sorted { $0.order < $1.order }
    }

    public static func starter() -> StageChaseProject {
        let columns = 4
        let rows = 3
        let slices = (0..<(columns * rows)).map { index in
            let column = index % columns
            let row = index / columns
            let x0 = Double(column) / Double(columns)
            let y0 = Double(row) / Double(rows)
            let x1 = Double(column + 1) / Double(columns)
            let y1 = Double(row + 1) / Double(rows)
            return StageSlice(
                id: "slice-\(index + 1)",
                name: "Slice \(index + 1)",
                screenName: "Main Screen",
                points: [
                    StagePoint(x: x0, y: y0),
                    StagePoint(x: x1, y: y0),
                    StagePoint(x: x1, y: y1),
                    StagePoint(x: x0, y: y1)
                ]
            )
        }
        let steps = (0..<16).map { index in
            let active = slices.enumerated().compactMap { sliceIndex, slice in
                (sliceIndex % 4 == index % 4) ? slice.id : nil
            }
            return ChaseStep(enabledSliceIDs: Set(active))
        }
        let widgets = [
            OSCWidget(title: "Video Master", kind: .fader, address: "/composition/master", order: 0),
            OSCWidget(title: "Audio Master", kind: .fader, address: "/composition/audio/volume", order: 1),
            OSCWidget(title: "Next Column", kind: .trigger, address: "/composition/connectnextcolumn", order: 2),
            OSCWidget(title: "Strobe", kind: .strobe, address: "", order: 3)
        ]
        return StageChaseProject(
            title: "Untitled Show",
            canvasWidth: 1920,
            canvasHeight: 1080,
            slices: slices,
            views: [ChaseView(name: "All Slices", visibleSliceIDs: Set(slices.map(\.id)))],
            sequences: [ChaseSequence(name: "Sequence 1", steps: steps)],
            widgets: widgets
        )
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ProjectError.unsupportedSchema(schemaVersion)
        }
        guard canvasWidth.isFinite, canvasHeight.isFinite, canvasWidth > 0, canvasHeight > 0 else {
            throw ProjectError.invalidCanvas
        }
        let sliceIDs = Set(slices.map(\.id))
        guard sliceIDs.count == slices.count else { throw ProjectError.duplicateSliceID }
        guard !sequences.isEmpty, sequences.allSatisfy({ (1...1024).contains($0.steps.count) }) else {
            throw ProjectError.invalidStepCount
        }
        guard sequences.allSatisfy({
            $0.stepDuration.isFinite && (0.025...60).contains($0.stepDuration) && (0...32).contains($0.echoes)
        }) else {
            throw ProjectError.invalidPlaybackSettings
        }
        guard views.allSatisfy({ $0.visibleSliceIDs.isSubset(of: sliceIDs) }) else {
            throw ProjectError.unknownSliceReference
        }
        guard sequences.allSatisfy({ sequence in
            sequence.steps.allSatisfy { $0.enabledSliceIDs.isSubset(of: sliceIDs) }
        }) else {
            throw ProjectError.unknownSliceReference
        }
        guard widgets.allSatisfy({ OSCAddress.isValid($0.address) || ($0.kind == .strobe && $0.address.isEmpty) }) else {
            throw ProjectError.invalidWidgetAddress
        }
        guard widgets.allSatisfy({
            $0.minimum.isFinite && $0.maximum.isFinite && $0.restingValue.isFinite && $0.minimum <= $0.maximum
        }) else {
            throw ProjectError.invalidWidgetRange
        }
    }
}

public enum ProjectError: Error, Equatable, LocalizedError {
    case unsupportedSchema(Int)
    case invalidCanvas
    case duplicateSliceID
        case invalidStepCount
        case invalidPlaybackSettings
        case unknownSliceReference
        case invalidWidgetAddress
        case invalidWidgetRange

    public var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version): "This project uses an unsupported format version (\(version))."
        case .invalidCanvas: "The project canvas must have a valid width and height."
        case .duplicateSliceID: "The project contains duplicate slice identifiers."
        case .invalidStepCount: "Each sequence must contain between 1 and 1024 steps."
        case .invalidPlaybackSettings: "Sequence speed or echo settings are outside the supported range."
        case .unknownSliceReference: "A view or sequence refers to a slice that does not exist."
        case .invalidWidgetAddress: "A widget contains an invalid OSC address."
        case .invalidWidgetRange: "A widget's numeric range is invalid."
        }
    }
}

public enum ProjectCodec {
    public static func encode(_ project: StageChaseProject) throws -> Data {
        try project.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(project)
    }

    public static func decode(_ data: Data) throws -> StageChaseProject {
        let project = try JSONDecoder().decode(StageChaseProject.self, from: data)
        try project.validate()
        return project
    }
}
