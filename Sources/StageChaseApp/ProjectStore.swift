import AppKit
import Combine
import Foundation
import StageChaseCore

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var project = StageChaseProject.starter()
    @Published var selectedSequenceIndex = 0
    @Published var selectedStepIndex = 0
    @Published var selectedViewIndex = 0
    @Published var isPlaying = false
    @Published var message: String?
    @Published var errorMessage: String?
    @Published private(set) var currentFileURL: URL?

    private var playbackTask: Task<Void, Never>?
    private var pingPongForward = true
    private var undoStack: [StageChaseProject] = []
    private var redoStack: [StageChaseProject] = []
    private let autosaveURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StageChase", isDirectory: true)
        autosaveURL = appSupport.appendingPathComponent("Autosave.stagechase")
        if let data = try? Data(contentsOf: autosaveURL),
           let saved = try? ProjectCodec.decode(data) {
            project = saved
            message = "Recovered autosaved project"
        }
        persistAutosave()
    }

    var selectedSequence: ChaseSequence {
        project.sequences[min(selectedSequenceIndex, project.sequences.count - 1)]
    }

    var selectedStep: ChaseStep {
        selectedSequence.steps[min(selectedStepIndex, selectedSequence.steps.count - 1)]
    }

    var previewSliceIDs: Set<String> {
        var active = selectedStep.enabledSliceIDs
        guard selectedSequence.echoes > 0, selectedSequence.steps.count > 1 else { return active }
        for offset in 1...min(selectedSequence.echoes, selectedSequence.steps.count - 1) {
            let previous: Int
            switch selectedSequence.direction {
            case .forward, .pingPong, .random:
                previous = (selectedStepIndex - offset + selectedSequence.steps.count) % selectedSequence.steps.count
            case .reverse:
                previous = (selectedStepIndex + offset) % selectedSequence.steps.count
            }
            active.formUnion(selectedSequence.steps[previous].enabledSliceIDs)
        }
        return active
    }

    var visibleSliceIDs: Set<String> {
        guard project.views.indices.contains(selectedViewIndex) else {
            return Set(project.slices.map(\.id))
        }
        return project.views[selectedViewIndex].visibleSliceIDs
    }

    func newProject() {
        stopPlayback()
        project = .starter()
        undoStack.removeAll()
        redoStack.removeAll()
        selectedSequenceIndex = 0
        selectedStepIndex = 0
        selectedViewIndex = 0
        currentFileURL = nil
        persistAutosave()
        message = "New show ready"
    }

    func openProject(_ url: URL) {
        do {
            let data = try Data(contentsOf: url)
            let loaded = try ProjectCodec.decode(data)
            stopPlayback()
            project = loaded
            undoStack.removeAll()
            redoStack.removeAll()
            selectedSequenceIndex = 0
            selectedStepIndex = 0
            selectedViewIndex = 0
            currentFileURL = url
            message = "Opened \(url.lastPathComponent)"
            errorMessage = nil
            persistAutosave()
        } catch {
            errorMessage = "Could not open project: \(error.localizedDescription)"
        }
    }

    func saveProject(to url: URL? = nil) {
        let destination = url ?? currentFileURL ?? autosaveURL
        do {
            let data = try ProjectCodec.encode(project)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: .atomic)
            currentFileURL = destination == autosaveURL ? currentFileURL : destination
            message = "Saved \(destination.lastPathComponent)"
            errorMessage = nil
        } catch {
            errorMessage = "Could not save project: \(error.localizedDescription)"
        }
    }

    func importAdvancedOutput(from url: URL) {
        do {
            let imported = try AdvancedOutputImporter.importData(Data(contentsOf: url))
            checkpoint()
            let newIDs = Set(imported.slices.map(\.id))
            let hasRelinkableSteps = project.sequences.contains { sequence in
                sequence.steps.contains { !$0.enabledSliceIDs.intersection(newIDs).isEmpty }
            }
            var updated = project
            updated.title = url.deletingPathExtension().lastPathComponent
            updated.canvasWidth = imported.canvasWidth
            updated.canvasHeight = imported.canvasHeight
            updated.slices = imported.slices
            updated.views = [
                ChaseView(name: "All Slices", visibleSliceIDs: newIDs)
            ]
            updated.sequences = project.sequences.map { sequence in
                var sequence = sequence
                sequence.steps = sequence.steps.map { step in
                    var step = step
                    step.enabledSliceIDs.formIntersection(newIDs)
                    return step
                }
                return sequence
            }
            if !hasRelinkableSteps, !updated.sequences.isEmpty {
                let stepCount = min(16, max(imported.slices.count, 1))
                updated.sequences[0].steps = (0..<stepCount).map { stepIndex in
                    let active = imported.slices.enumerated().compactMap { sliceIndex, slice in
                        sliceIndex % stepCount == stepIndex ? slice.id : nil
                    }
                    return ChaseStep(enabledSliceIDs: Set(active))
                }
            }
            try updated.validate()
            project = updated
            selectedViewIndex = 0
            selectedSequenceIndex = min(selectedSequenceIndex, project.sequences.count - 1)
            selectedStepIndex = min(selectedStepIndex, selectedSequence.steps.count - 1)
            persistAutosave()
            let skipped = imported.warnings.count
            message = skipped == 0
                ? "Imported \(imported.slices.count) slices"
                : "Imported \(imported.slices.count) slices; skipped \(skipped)"
            errorMessage = imported.warnings.isEmpty ? nil : imported.warnings.joined(separator: "\n")
        } catch {
            errorMessage = "Could not import preset: \(error.localizedDescription)"
        }
    }

    func setSequence(_ index: Int) {
        guard project.sequences.indices.contains(index) else { return }
        selectedSequenceIndex = index
        selectedStepIndex = min(selectedStepIndex, selectedSequence.steps.count - 1)
        pingPongForward = true
    }

    func setStep(_ index: Int) {
        guard selectedSequence.steps.indices.contains(index) else { return }
        selectedStepIndex = index
    }

    func setView(_ index: Int) {
        guard project.views.indices.contains(index) else { return }
        selectedViewIndex = index
    }

    func toggleSlice(_ id: String) {
        checkpoint()
        mutateSelectedStep { step in
            if step.enabledSliceIDs.contains(id) {
                step.enabledSliceIDs.remove(id)
            } else {
                step.enabledSliceIDs.insert(id)
            }
        }
    }

    func setSlice(_ id: String, enabled: Bool) {
        checkpoint()
        mutateSelectedStep { step in
            if enabled { step.enabledSliceIDs.insert(id) }
            else { step.enabledSliceIDs.remove(id) }
        }
    }

    func addStep() {
        guard selectedSequence.steps.count < 1024 else { return }
        checkpoint()
        updateSequence { sequence in
            let next = min(selectedStepIndex + 1, sequence.steps.count)
            let copy = sequence.steps[max(selectedStepIndex, 0)]
            sequence.steps.insert(ChaseStep(enabledSliceIDs: copy.enabledSliceIDs), at: next)
            selectedStepIndex = next
        }
    }

    func removeStep() {
        guard selectedSequence.steps.count > 1 else { return }
        checkpoint()
        updateSequence { sequence in
            sequence.steps.remove(at: selectedStepIndex)
            selectedStepIndex = min(selectedStepIndex, sequence.steps.count - 1)
        }
    }

    func duplicateStep(at index: Int) {
        guard selectedSequence.steps.indices.contains(index), selectedSequence.steps.count < 1024 else { return }
        checkpoint()
        updateSequence { sequence in
            let source = sequence.steps[index]
            sequence.steps.insert(ChaseStep(enabledSliceIDs: source.enabledSliceIDs), at: index + 1)
            selectedStepIndex = index + 1
        }
    }

    func moveStep(_ id: String, before targetID: String) {
        guard id != targetID,
              let source = selectedSequence.steps.firstIndex(where: { $0.id == id }),
              let target = selectedSequence.steps.firstIndex(where: { $0.id == targetID }) else { return }
        checkpoint()
        updateSequence { sequence in
            let step = sequence.steps.remove(at: source)
            let insertion = source < target ? target - 1 : target
            sequence.steps.insert(step, at: insertion)
            selectedStepIndex = insertion
        }
    }

    func addSequence(copyCurrent: Bool = false) {
        checkpoint()
        let base = copyCurrent ? selectedSequence.steps : [ChaseStep()]
        project.sequences.append(ChaseSequence(name: "Sequence \(project.sequences.count + 1)", steps: base))
        selectedSequenceIndex = project.sequences.count - 1
        selectedStepIndex = 0
        persistAutosave()
    }

    func removeSequence(at index: Int) {
        guard project.sequences.count > 1, project.sequences.indices.contains(index) else { return }
        checkpoint()
        project.sequences.remove(at: index)
        selectedSequenceIndex = min(selectedSequenceIndex, project.sequences.count - 1)
        selectedStepIndex = min(selectedStepIndex, selectedSequence.steps.count - 1)
        persistAutosave()
    }

    func renameSequence(at index: Int, to name: String) {
        guard project.sequences.indices.contains(index) else { return }
        checkpoint()
        project.sequences[index].name = name
        persistAutosave()
    }

    func duplicateSequence(at index: Int) {
        guard project.sequences.indices.contains(index) else { return }
        checkpoint()
        var copy = project.sequences[index]
        copy.id = UUID().uuidString
        copy.name += " Copy"
        copy.steps = copy.steps.map { ChaseStep(enabledSliceIDs: $0.enabledSliceIDs) }
        project.sequences.insert(copy, at: index + 1)
        selectedSequenceIndex = index + 1
        selectedStepIndex = 0
        persistAutosave()
    }

    func moveSequence(_ id: String, before targetID: String) {
        guard id != targetID,
              let source = project.sequences.firstIndex(where: { $0.id == id }),
              let target = project.sequences.firstIndex(where: { $0.id == targetID }) else { return }
        checkpoint()
        let sequence = project.sequences.remove(at: source)
        let insertion = source < target ? target - 1 : target
        project.sequences.insert(sequence, at: insertion)
        selectedSequenceIndex = insertion
        persistAutosave()
    }

    func addView() {
        checkpoint()
        project.views.append(
            ChaseView(name: "View \(project.views.count + 1)", visibleSliceIDs: Set(project.slices.map(\.id)))
        )
        selectedViewIndex = project.views.count - 1
        persistAutosave()
    }

    func toggleViewSlice(_ id: String) {
        guard project.views.indices.contains(selectedViewIndex) else { return }
        checkpoint()
        if project.views[selectedViewIndex].visibleSliceIDs.contains(id) {
            project.views[selectedViewIndex].visibleSliceIDs.remove(id)
        } else {
            project.views[selectedViewIndex].visibleSliceIDs.insert(id)
        }
        persistAutosave()
    }

    func renameView(at index: Int, to name: String) {
        guard project.views.indices.contains(index) else { return }
        checkpoint()
        project.views[index].name = name
        persistAutosave()
    }

    func updatePlaybackSettings(
        direction: ChaseDirection? = nil,
        stepDuration: Double? = nil,
        scaling: SliceScaling? = nil,
        echoes: Int? = nil
    ) {
        updateSequence { sequence in
            if let direction { sequence.direction = direction }
            if let stepDuration { sequence.stepDuration = min(max(stepDuration, 0.025), 60) }
            if let scaling { sequence.scaling = scaling }
            if let echoes { sequence.echoes = min(max(echoes, 0), 32) }
        }
    }

    func addWidget(kind: WidgetKind) {
        let defaults: (String, String)
        switch kind {
        case .fader: defaults = ("New Fader", "/composition/master")
        case .toggle: defaults = ("New Toggle", "/composition/layers/1/bypassed")
        case .trigger: defaults = ("New Trigger", "/composition/connectnextcolumn")
        case .strobe: defaults = ("Strobe", "")
        }
        let widget = OSCWidget(
            title: defaults.0,
            kind: kind,
            address: defaults.1,
            order: project.widgets.count
        )
        project.widgets.append(widget)
        persistAutosave()
    }

    func updateWidget(_ id: String, _ update: (inout OSCWidget) -> Void) {
        guard let index = project.widgets.firstIndex(where: { $0.id == id }) else { return }
        update(&project.widgets[index])
        project.widgets[index].strobeRate = min(max(project.widgets[index].strobeRate, 1), 20)
        persistAutosave()
    }

    func removeWidget(_ id: String) {
        checkpoint()
        project.widgets.removeAll { $0.id == id }
        normalizeWidgetOrder()
        persistAutosave()
    }

    func moveWidget(_ id: String, before targetID: String) {
        guard id != targetID,
              let source = project.widgets.firstIndex(where: { $0.id == id }),
              let target = project.widgets.firstIndex(where: { $0.id == targetID }) else { return }
        checkpoint()
        let item = project.widgets.remove(at: source)
        project.widgets.insert(item, at: source < target ? target - 1 : target)
        normalizeWidgetOrder()
        persistAutosave()
    }

    func togglePlayback() {
        if isPlaying {
            stopPlayback()
            return
        }
        pingPongForward = true
        isPlaying = true
        playbackTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isPlaying else { return }
                let delay = Duration.milliseconds(Int(self.selectedSequence.stepDuration * 1000))
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, self.isPlaying else { return }
                self.advancePlayback()
            }
        }
    }

    func stopPlayback() {
        playbackTask?.cancel()
        playbackTask = nil
        isPlaying = false
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(project)
        project = previous
        constrainSelection()
        persistAutosave()
        message = "Undid last edit"
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(project)
        project = next
        constrainSelection()
        persistAutosave()
        message = "Redid edit"
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    private func mutateSelectedStep(_ update: (inout ChaseStep) -> Void) {
        updateSequence { sequence in
            guard sequence.steps.indices.contains(selectedStepIndex) else { return }
            update(&sequence.steps[selectedStepIndex])
        }
    }

    private func updateSequence(_ update: (inout ChaseSequence) -> Void) {
        guard project.sequences.indices.contains(selectedSequenceIndex) else { return }
        update(&project.sequences[selectedSequenceIndex])
        persistAutosave()
    }

    private func normalizeWidgetOrder() {
        for index in project.widgets.indices { project.widgets[index].order = index }
    }

    private func checkpoint() {
        undoStack.append(project)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func constrainSelection() {
        selectedSequenceIndex = min(selectedSequenceIndex, project.sequences.count - 1)
        selectedStepIndex = min(selectedStepIndex, selectedSequence.steps.count - 1)
        selectedViewIndex = min(selectedViewIndex, max(project.views.count - 1, 0))
    }

    private func advancePlayback() {
        let count = selectedSequence.steps.count
        guard count > 1 else { return }
        switch selectedSequence.direction {
        case .forward:
            selectedStepIndex = (selectedStepIndex + 1) % count
        case .reverse:
            selectedStepIndex = (selectedStepIndex - 1 + count) % count
        case .random:
            selectedStepIndex = Int.random(in: 0..<count)
        case .pingPong:
            if pingPongForward && selectedStepIndex == count - 1 { pingPongForward = false }
            else if !pingPongForward && selectedStepIndex == 0 { pingPongForward = true }
            selectedStepIndex += pingPongForward ? 1 : -1
        }
    }

    private func persistAutosave() {
        do {
            let data = try ProjectCodec.encode(project)
            try FileManager.default.createDirectory(
                at: autosaveURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: autosaveURL, options: .atomic)
            try LiveProjectSnapshot.encode(project).write(
                to: autosaveURL.deletingLastPathComponent().appendingPathComponent("LiveProject.stagechase-live"),
                options: .atomic
            )
        } catch {
            errorMessage = "Autosave failed: \(error.localizedDescription)"
        }
    }
}
