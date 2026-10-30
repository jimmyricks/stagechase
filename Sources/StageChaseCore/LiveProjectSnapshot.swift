import Foundation

public enum LiveProjectSnapshot {
    public static func encode(_ project: StageChaseProject) throws -> Data {
        try project.validate()
        let sliceIndices = Dictionary(uniqueKeysWithValues: project.slices.enumerated().map { ($1.id, $0) })
        var lines = ["STAGECHASE 1"]
        lines.append("\(number(project.canvasWidth)) \(number(project.canvasHeight))")
        lines.append("\(project.slices.count)")
        for slice in project.slices {
            lines.append("\(slice.points.count)")
            lines.append(slice.points.map { "\(number($0.x)) \(number($0.y))" }.joined(separator: " "))
        }
        lines.append("\(project.sequences.count)")
        for sequence in project.sequences {
            lines.append("\(sequence.steps.count) \(sequence.direction.rawValue) \(number(sequence.stepDuration)) \(sequence.scaling.rawValue) \(sequence.echoes)")
            for step in sequence.steps {
                let indices = step.enabledSliceIDs.compactMap { sliceIndices[$0] }.sorted()
                lines.append(([String(indices.count)] + indices.map(String.init)).joined(separator: " "))
            }
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}
