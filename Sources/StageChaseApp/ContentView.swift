import AppKit
import Combine
import StageChaseCore
import SwiftUI
import UniformTypeIdentifiers

private enum Workspace: String, CaseIterable {
    case chase = "Chase"
    case controls = "Controls"
}

struct ContentView: View {
    @StateObject private var store = ProjectStore()
    @StateObject private var osc = OSCTransport()
    @State private var workspace: Workspace = .chase
    @State private var showingError = false
    @State private var showingNewConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1)
            Group {
                if workspace == .chase {
                    ChaseWorkspace(store: store)
                } else {
                    ControlsWorkspace(store: store, osc: osc)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if let message = store.message {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.mint)
                    Text(message).foregroundStyle(Color.white.opacity(0.72))
                    Spacer()
                }
                .font(.system(size: 12))
                .padding(.horizontal, 20)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.035))
            }
        }
        .frame(minWidth: 1080, minHeight: 720)
        .background(Palette.background)
        .foregroundStyle(Palette.text)
        .onChange(of: store.errorMessage) { _, value in showingError = value != nil }
        .alert("StageChase", isPresented: $showingError) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .onDisappear {
            store.stopPlayback()
            osc.stopAllStrobes(widgets: store.project.widgets)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.3.group.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 34, height: 34)
                    .background(Palette.accent.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 1) {
                    Text("STAGECHASE").font(.system(size: 13, weight: .bold, design: .rounded)).tracking(1.2)
                    Text("RESOLUME COMPANION").font(.system(size: 11, weight: .medium)).tracking(0.7).foregroundStyle(Palette.muted)
                }
            }
            Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 30)
            Text(store.project.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 12)
            Button { showingNewConfirmation = true } label: {
                Label("New", systemImage: "plus")
            }
            .buttonStyle(QuietButtonStyle())
            Button { store.undo() } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(!store.canUndo)
            Button { store.redo() } label: {
                Label("Redo", systemImage: "arrow.uturn.forward")
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(!store.canRedo)
            Button(action: openProject) {
                Label("Open", systemImage: "folder").labelStyle(.titleAndIcon)
            }
            .buttonStyle(QuietButtonStyle())
            Button(action: importPreset) {
                Label("Import Output", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(QuietButtonStyle())
            Button(action: saveProject) {
                Label("Save", systemImage: "square.and.arrow.down.fill")
            }
            .buttonStyle(QuietButtonStyle())
            HStack(spacing: 2) {
                ForEach(Workspace.allCases, id: \.self) { item in
                    Button {
                        workspace = item
                    } label: {
                        Text(item.rawValue)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(workspace == item ? Palette.text : Palette.muted)
                            .frame(width: 73, height: 30)
                            .background(
                                workspace == item ? Palette.panel : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Color.black.opacity(0.2), in: RoundedRectangle(cornerRadius: 8))
            .frame(width: 158, height: 36)
            HStack(spacing: 7) {
                Circle()
                    .fill(osc.status.contains("failed") || osc.status.contains("Invalid") ? Palette.warning : Palette.accent)
                    .frame(width: 7, height: 7)
                Text(osc.status == "Not connected" ? "OSC ready" : "OSC")
                    .font(.system(size: 12, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.05), in: Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(Palette.header)
        .confirmationDialog("Start a new show?", isPresented: $showingNewConfirmation, titleVisibility: .visible) {
            Button("Start New Show", role: .destructive) { store.newProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the current autosaved project. Save a copy first if you want to keep it.")
        }
    }

    private func openProject() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stagechase") ?? .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.openProject(url)
        }
    }

    private func importPreset() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xml") ?? .xml,
            UTType(filenameExtension: "avc") ?? .data
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            store.importAdvancedOutput(from: url)
        }
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "stagechase") ?? .json]
        panel.nameFieldStringValue = store.project.title
            .replacingOccurrences(of: "/", with: "-") + ".stagechase"
        if panel.runModal() == .OK, let url = panel.url {
            store.saveProject(to: url)
        }
    }
}

private struct ChaseWorkspace: View {
    @ObservedObject var store: ProjectStore
    @State private var renameViewTarget: Int?
    @State private var renameViewText = ""

    var body: some View {
        HStack(spacing: 0) {
            SequenceSidebar(store: store)
                .frame(width: 218)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(spacing: 0) {
                canvasToolbar
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                SliceCanvas(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)
                StepTimeline(store: store)
            }
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            SliceInspector(store: store)
                .frame(width: 235)
        }
        .background(Palette.background)
        .alert("Rename view", isPresented: Binding(
            get: { renameViewTarget != nil },
            set: { if !$0 { renameViewTarget = nil } }
        )) {
            TextField("View name", text: $renameViewText)
            Button("Cancel", role: .cancel) { renameViewTarget = nil }
            Button("Save") {
                if let renameViewTarget {
                    store.renameView(at: renameViewTarget, to: renameViewText)
                }
                renameViewTarget = nil
            }
        }
    }

    private var canvasToolbar: some View {
        HStack(spacing: 14) {
            Label("INPUT MAP", systemImage: "viewfinder")
                .font(.system(size: 11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.muted)
            Menu {
                ForEach(Array(store.project.views.enumerated()), id: \.element.id) { index, view in
                    Button(view.name) { store.setView(index) }
                }
                Divider()
                Button("Add View", systemImage: "plus") { store.addView() }
                if store.project.views.indices.contains(store.selectedViewIndex) {
                    Button("Rename Current View", systemImage: "pencil") {
                        renameViewTarget = store.selectedViewIndex
                        renameViewText = store.project.views[store.selectedViewIndex].name
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    Text(store.project.views.indices.contains(store.selectedViewIndex)
                         ? store.project.views[store.selectedViewIndex].name : "All Slices")
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.panel, in: RoundedRectangle(cornerRadius: 7))
            }
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(Palette.accent).frame(width: 6, height: 6)
                Text("\(store.project.slices.count) SLICES")
                Text("·").foregroundStyle(Palette.muted)
                Text("\(store.project.canvasWidth.formatted(.number.precision(.fractionLength(0)))) × \(store.project.canvasHeight.formatted(.number.precision(.fractionLength(0))))")
            }
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(Palette.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}

private struct SequenceSidebar: View {
    @ObservedObject var store: ProjectStore
    @State private var renameTarget: Int?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SEQUENCES").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                Spacer()
                Button { store.addSequence() } label: {
                    Image(systemName: "plus").font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
                .buttonStyle(.plain)
                .help("Add sequence")
            }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(Array(store.project.sequences.enumerated()), id: \.element.id) { index, sequence in
                        Button {
                            store.setSequence(index)
                        } label: {
                            HStack(spacing: 10) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(index == store.selectedSequenceIndex ? Palette.accent : Color.white.opacity(0.13))
                                    .frame(width: 3, height: 27)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(sequence.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                    Text("\(sequence.steps.count) steps")
                                        .font(.system(size: 11)).foregroundStyle(Palette.muted)
                                }
                                Spacer()
                                if index == store.selectedSequenceIndex {
                                    Image(systemName: "arrowtriangle.right.fill")
                                        .font(.system(size: 8)).foregroundStyle(Palette.accent)
                                }
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 8)
                            .background(index == store.selectedSequenceIndex ? Palette.accent.opacity(0.11) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .draggable(sequence.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let source = ids.first else { return false }
                            store.moveSequence(source, before: sequence.id)
                            return true
                        }
                        .contextMenu {
                            Button("Rename") {
                                renameTarget = index
                                renameText = sequence.name
                            }
                            Button("Duplicate") { store.duplicateSequence(at: index) }
                            Button("Delete", role: .destructive) { store.removeSequence(at: index) }
                                .disabled(store.project.sequences.count <= 1)
                        }
                    }
                }
            }
            PlaybackSettings(store: store)
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 9) {
                Text("CURRENT STEP")
                    .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Palette.muted)
                Text("\(store.selectedStepIndex + 1, format: .number.precision(.integerLength(2)))")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.text)
                Text("of \(store.selectedSequence.steps.count)")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(13)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(15)
        .background(Palette.sidebar)
        .alert("Rename sequence", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("Sequence name", text: $renameText)
            Button("Cancel", role: .cancel) { renameTarget = nil }
            Button("Save") {
                if let renameTarget { store.renameSequence(at: renameTarget, to: renameText) }
                renameTarget = nil
            }
        }
    }
}

private struct PlaybackSettings: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PLAYBACK")
                .font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Palette.muted)
            Menu {
                ForEach(ChaseDirection.allCases, id: \.self) { direction in
                    Button(direction.title) {
                        store.updatePlaybackSettings(direction: direction)
                    }
                }
            } label: {
                settingRow("Direction", value: store.selectedSequence.direction.title)
            }
            Menu {
                ForEach(SliceScaling.allCases, id: \.self) { scaling in
                    Button(scaling.title) { store.updatePlaybackSettings(scaling: scaling) }
                }
            } label: {
                settingRow("Scaling", value: store.selectedSequence.scaling.title)
            }
            HStack {
                Text("Echoes").font(.system(size: 11, weight: .medium))
                Spacer()
                Stepper(
                    value: Binding(
                        get: { store.selectedSequence.echoes },
                        set: { store.updatePlaybackSettings(echoes: $0) }
                    ),
                    in: 0...32
                ) {
                    Text("\(store.selectedSequence.echoes)")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .frame(width: 25, alignment: .trailing)
                }
                .labelsHidden()
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("Step speed").font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text("\(1 / store.selectedSequence.stepDuration, format: .number.precision(.fractionLength(1))) steps/s")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
                }
                Slider(
                    value: Binding(
                        get: { store.selectedSequence.stepDuration },
                        set: { store.updatePlaybackSettings(stepDuration: $0) }
                    ),
                    in: 0.05...2
                )
                .tint(Palette.accent)
            }
        }
        .padding(11)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 10))
    }

    private func settingRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value).foregroundStyle(Palette.muted)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .bold)).foregroundStyle(Palette.muted)
        }
        .font(.system(size: 11, weight: .medium))
        .padding(.vertical, 2)
    }
}

private struct SliceCanvas: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        GeometryReader { proxy in
            let innerSize = CGSize(width: max(proxy.size.width - 24, 1), height: max(proxy.size.height - 24, 1))
            let canvasSize = fittedCanvasSize(in: innerSize)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(red: 0.045, green: 0.063, blue: 0.083))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    }
                Canvas { context, size in
                    let mapSize = fittedCanvasSize(in: size)
                    let offset = CGPoint(x: (size.width - mapSize.width) / 2, y: (size.height - mapSize.height) / 2)
                    for slice in store.project.slices where store.visibleSliceIDs.contains(slice.id) {
                        let points = slice.points.map {
                            CGPoint(x: offset.x + CGFloat($0.x) * mapSize.width, y: offset.y + CGFloat($0.y) * mapSize.height)
                        }
                        guard let first = points.first else { continue }
                        var path = Path()
                        path.move(to: first)
                        points.dropFirst().forEach { path.addLine(to: $0) }
                        path.closeSubpath()
                        let active = store.selectedStep.enabledSliceIDs.contains(slice.id)
                        let echoed = !active && store.previewSliceIDs.contains(slice.id)
                        let fill = active ? Palette.accent.opacity(0.76) : (echoed ? Color.blue.opacity(0.48) : Color(red: 0.13, green: 0.17, blue: 0.21))
                        context.fill(path, with: .color(fill))
                        context.stroke(
                            path,
                            with: .color(active ? Palette.accent : (echoed ? Color.blue.opacity(0.8) : Color.white.opacity(0.16))),
                            lineWidth: 1.4
                        )
                        let center = CGPoint(
                            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
                            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
                        )
                        context.draw(
                            Text(slice.name).font(.system(size: min(12, max(11, mapSize.width / 45)), weight: .semibold))
                                .foregroundColor(active ? Color.black.opacity(0.85) : Color.white.opacity(0.8)),
                            at: center
                        )
                    }
                }
                .padding(12)
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        guard canvasSize.width > 0, canvasSize.height > 0 else { return }
                        let point = StagePoint(
                            x: Double((value.location.x - (proxy.size.width - canvasSize.width) / 2) / canvasSize.width),
                            y: Double((value.location.y - (proxy.size.height - canvasSize.height) / 2) / canvasSize.height)
                        )
                        if let slice = store.project.slices.first(where: {
                            store.visibleSliceIDs.contains($0.id) && polygonContains(point, $0.points)
                        }) {
                            store.toggleSlice(slice.id)
                        }
                    }
                )
            }
            .padding(18)
        }
    }

    private func fittedCanvasSize(in size: CGSize) -> CGSize {
        let width = max(store.project.canvasWidth, 1)
        let height = max(store.project.canvasHeight, 1)
        let scale = min(size.width / width, size.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }

    private func polygonContains(_ point: StagePoint, _ polygon: [StagePoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false
        var previous = polygon.count - 1
        for current in polygon.indices {
            let a = polygon[current]
            let b = polygon[previous]
            let intersects = (a.y > point.y) != (b.y > point.y) &&
                point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
            if intersects { inside.toggle() }
            previous = current
        }
        return inside
    }
}

private struct SliceInspector: View {
    @ObservedObject var store: ProjectStore
    @State private var search = ""

    private var slices: [StageSlice] {
        store.project.slices.filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.screenName.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("SLICES").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                Spacer()
                Text("\(store.selectedStep.enabledSliceIDs.count) ON")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(Palette.accent)
            }
            TextField("Find a slice", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(8)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(slices) { slice in
                        let active = store.selectedStep.enabledSliceIDs.contains(slice.id)
                        let visible = store.visibleSliceIDs.contains(slice.id)
                        HStack(spacing: 8) {
                            Button { store.toggleSlice(slice.id) } label: {
                                HStack(spacing: 9) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(active ? Palette.accent : Color.white.opacity(0.12))
                                    .frame(width: 14, height: 14)
                                    .overlay {
                                        if active {
                                            Image(systemName: "checkmark").font(.system(size: 8, weight: .black)).foregroundStyle(.black)
                                        }
                                    }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(slice.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    Text(slice.screenName).font(.system(size: 11)).foregroundStyle(Palette.muted).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                store.toggleViewSlice(slice.id)
                            } label: {
                                Image(systemName: visible ? "eye.fill" : "eye.slash")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(visible ? Palette.muted : Palette.warning)
                                    .frame(width: 22, height: 28)
                            }
                            .buttonStyle(.plain)
                            .help(visible ? "Hide from this view" : "Show in this view")
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(active ? Palette.accent.opacity(0.07) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            Spacer(minLength: 0)
            Text("Click a slice on the map or in this list to toggle it for the selected step.")
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Palette.sidebar)
    }
}

private struct StepTimeline: View {
    @ObservedObject var store: ProjectStore

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 9) {
                Text(store.selectedSequence.name).font(.system(size: 12, weight: .semibold))
                Text("·").foregroundStyle(Palette.muted)
                Text("\(store.selectedSequence.steps.count) STEPS")
                    .font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(Palette.muted)
                Spacer()
                Button { store.setStep(max(store.selectedStepIndex - 1, 0)) } label: {
                    Image(systemName: "backward.end.fill")
                }
                .buttonStyle(IconButtonStyle())
                Button { store.togglePlayback() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                }
                .buttonStyle(AccentIconButtonStyle())
                Button { store.setStep(min(store.selectedStepIndex + 1, store.selectedSequence.steps.count - 1)) } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(IconButtonStyle())
                Button { store.removeStep() } label: { Image(systemName: "minus") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(store.selectedSequence.steps.count <= 1)
                Button { store.addStep() } label: { Image(systemName: "plus") }
                    .buttonStyle(IconButtonStyle())
                    .disabled(store.selectedSequence.steps.count >= 1024)
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach(Array(store.selectedSequence.steps.enumerated()), id: \.element.id) { index, step in
                        Button { store.setStep(index) } label: {
                            VStack(spacing: 5) {
                                Text("\(index + 1)")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                HStack(spacing: 2) {
                                    ForEach(0..<min(step.enabledSliceIDs.count, 4), id: \.self) { _ in
                                        Capsule().fill(index == store.selectedStepIndex ? Color.black.opacity(0.65) : Palette.accent)
                                            .frame(width: 5, height: 3)
                                    }
                                }
                                .frame(height: 3)
                            }
                            .foregroundStyle(index == store.selectedStepIndex ? Color.black : Palette.text)
                            .frame(width: 43, height: 47)
                            .background(index == store.selectedStepIndex ? Palette.accent : Palette.panel,
                                        in: RoundedRectangle(cornerRadius: 8))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.white.opacity(index == store.selectedStepIndex ? 0 : 0.06), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .draggable(step.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let source = ids.first else { return false }
                            store.moveStep(source, before: step.id)
                            return true
                        }
                        .contextMenu {
                            Button("Duplicate Step") { store.duplicateStep(at: index) }
                                .disabled(store.selectedSequence.steps.count >= 1024)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(Palette.header.opacity(0.72))
    }
}

private struct ControlsWorkspace: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var osc: OSCTransport

    private let columns = [
        GridItem(.flexible(minimum: 280), spacing: 14, alignment: .top),
        GridItem(.flexible(minimum: 280), spacing: 14, alignment: .top)
    ]

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("WIDGETS").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Palette.muted)
                Text("Add a control").font(.system(size: 17, weight: .semibold))
                Text("Arrange cards by dragging them. Edit the OSC address on each card.")
                    .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(WidgetKind.allCases) { kind in
                    Button { store.addWidget(kind: kind) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: kind)).foregroundStyle(Palette.accent).frame(width: 18)
                            Text(kind.title).font(.system(size: 12, weight: .medium))
                            Spacer()
                            Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                        }
                        .padding(10)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                    .draggable(kind.rawValue)
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Text("ARENA OSC").font(.system(size: 11, weight: .bold)).tracking(0.8).foregroundStyle(Palette.muted)
                    Text("Enable OSC input in Arena Preferences. The default incoming port is 7000.")
                        .font(.system(size: 11)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
                }
                .padding(11)
                .background(Palette.background, in: RoundedRectangle(cornerRadius: 9))
            }
            .padding(18)
            .frame(width: 225, alignment: .leading)
            .background(Palette.sidebar)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Live controls").font(.system(size: 20, weight: .semibold))
                        Text("Local OSC dashboard for Resolume Arena")
                            .font(.system(size: 12)).foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        TextField("Host", text: $osc.host)
                            .textFieldStyle(.plain)
                            .frame(width: 120)
                        Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 20)
                        TextField("Port", text: $osc.portText)
                            .textFieldStyle(.plain)
                            .frame(width: 52)
                    }
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8))
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                    ForEach(store.project.widgets.sorted { $0.order < $1.order }) { widget in
                        WidgetCard(
                            widget: widget,
                            osc: osc,
                            update: { store.updateWidget(widget.id, $0) },
                            remove: { store.removeWidget(widget.id) }
                        )
                        .draggable(widget.id)
                        .dropDestination(for: String.self) { ids, _ in
                            guard let source = ids.first else { return false }
                            if let kind = WidgetKind(rawValue: source) {
                                store.addWidget(kind: kind)
                                return true
                            } else if store.project.widgets.contains(where: { $0.id == source }) {
                                store.moveWidget(source, before: widget.id)
                                return true
                            }
                            return false
                        }
                        .gridCellColumns(widget.width == .wide ? 2 : 1)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 8) {
                    Image(systemName: "paperplane.fill").font(.system(size: 10))
                    Text(osc.lastSent.isEmpty ? osc.status : osc.lastSent)
                        .lineLimit(1)
                    Spacer()
                    Text("UDP does not confirm delivery")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.muted)
                .padding(.top, 3)
            }
            .padding(22)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Palette.background)
    }

    private func icon(for kind: WidgetKind) -> String {
        switch kind {
        case .fader: "slider.horizontal.3"
        case .toggle: "switch.2"
        case .trigger: "bolt.fill"
        case .strobe: "flashlight.on.fill"
        }
    }
}

private struct WidgetCard: View {
    let widget: OSCWidget
    @ObservedObject var osc: OSCTransport
    let update: ((inout OSCWidget) -> Void) -> Void
    let remove: () -> Void
    @State private var faderValue: Double = 0.75
    @State private var toggleValue = false

    private var addressValid: Bool {
        OSCAddress.isValid(widget.address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 29, height: 29)
                    .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                TextField("Widget name", text: Binding(
                    get: { widget.title },
                    set: { value in update { $0.title = value } }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button {
                    update { $0.width = widget.width == .wide ? .compact : .wide }
                } label: {
                    Image(systemName: widget.width == .wide ? "rectangle.compress.vertical" : "rectangle.expand.vertical")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help(widget.width == .wide ? "Make compact" : "Make wide")
                Text(widget.kind.title.uppercased())
                    .font(.system(size: 11, weight: .bold)).tracking(0.5).foregroundStyle(Palette.muted)
                Button(action: remove) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Palette.muted)
                }
                .buttonStyle(.plain)
                .help("Remove widget")
            }
            TextField("/composition/…", text: Binding(
                get: { widget.address },
                set: { value in update { $0.address = value } }
            ))
            .textFieldStyle(.plain)
            .font(.system(size: 11, design: .monospaced))
            .padding(8)
            .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 6))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(addressValid ? Color.clear : Palette.warning.opacity(0.7), lineWidth: 1)
            }

            control
            if widget.kind == .strobe {
                VStack(alignment: .leading, spacing: 9) {
                    HStack {
                        Text("RATE").foregroundStyle(Palette.muted)
                        Slider(value: Binding(
                            get: { widget.strobeRate },
                            set: { value in update { $0.strobeRate = value } }
                        ), in: 1...20, step: 1)
                        Text("\(Int(widget.strobeRate)) Hz").monospacedDigit()
                    }
                    .font(.system(size: 11, weight: .bold))
                    HStack(spacing: 6) {
                        Text("Low")
                        valueField(widget.minimum) { value in
                            update { $0.minimum = min(value, $0.maximum); $0.restingValue = max($0.minimum, min($0.maximum, $0.restingValue)) }
                        }
                        Text("High")
                        valueField(widget.maximum) { value in
                            update { $0.maximum = max(value, $0.minimum); $0.restingValue = max($0.minimum, min($0.maximum, $0.restingValue)) }
                        }
                        Text("Rest")
                        valueField(widget.restingValue) { value in
                            update { $0.restingValue = max($0.minimum, min($0.maximum, value)) }
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                }
            } else if widget.kind == .fader {
                HStack(spacing: 8) {
                    Text("MIN").foregroundStyle(Palette.muted)
                    valueField(widget.minimum) { value in update { $0.minimum = min(value, $0.maximum) } }
                    Text("MAX").foregroundStyle(Palette.muted)
                    valueField(widget.maximum) { value in update { $0.maximum = max(value, $0.minimum) } }
                }
                .font(.system(size: 11, weight: .bold))
            }
            if !addressValid {
                Text(widget.kind == .strobe ? "Choose an OSC parameter before starting." : "Enter a valid OSC address.")
                    .font(.system(size: 11)).foregroundStyle(Palette.warning)
            }
        }
        .padding(14)
        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07), lineWidth: 1)
        }
        .onDisappear {
            if widget.kind == .strobe, osc.isStrobing(widget.id) {
                osc.stopStrobe(widget)
            }
        }
    }

    @ViewBuilder
    private var control: some View {
        switch widget.kind {
        case .fader:
            VStack(spacing: 7) {
                Slider(value: Binding(
                    get: { faderValue },
                    set: { value in
                        faderValue = value
                        let output = widget.minimum + Float(value) * (widget.maximum - widget.minimum)
                        osc.send(address: widget.address, value: output)
                    }
                ))
                HStack {
                    Text("\(widget.minimum, format: .number.precision(.fractionLength(2)))")
                    Spacer()
                    Text("\(widget.maximum, format: .number.precision(.fractionLength(2)))")
                }
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Palette.muted)
            }
            .disabled(!addressValid)
        case .toggle:
            Button {
                toggleValue.toggle()
                osc.send(address: widget.address, value: toggleValue ? widget.maximum : widget.minimum)
            } label: {
                Label(toggleValue ? "On" : "Off", systemImage: toggleValue ? "checkmark.circle.fill" : "circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(DashboardActionStyle(active: toggleValue))
            .disabled(!addressValid)
        case .trigger:
            Button {
                osc.trigger(address: widget.address)
            } label: {
                Label("Fire", systemImage: "bolt.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(DashboardActionStyle(active: false))
            .disabled(!addressValid)
        case .strobe:
            Button {
                osc.toggleStrobe(widget)
            } label: {
                Label(
                    osc.isStrobing(widget.id) ? "Stop strobe" : "Start strobe",
                    systemImage: osc.isStrobing(widget.id) ? "stop.fill" : "flashlight.on.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(DashboardActionStyle(active: osc.isStrobing(widget.id)))
            .disabled(!addressValid)
        }
    }

    private var icon: String {
        switch widget.kind {
        case .fader: "slider.horizontal.3"
        case .toggle: "switch.2"
        case .trigger: "bolt.fill"
        case .strobe: "flashlight.on.fill"
        }
    }

    private func valueField(_ value: Float, set: @escaping (Float) -> Void) -> some View {
        TextField("0", value: Binding(
            get: { Double(value) },
            set: { set(Float($0)) }
        ), format: .number.precision(.fractionLength(0...2)))
        .textFieldStyle(.plain)
        .frame(width: 37)
        .padding(.horizontal, 5)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
    }
}

private enum Palette {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.091)
    static let header = Color(red: 0.075, green: 0.094, blue: 0.118)
    static let sidebar = Color(red: 0.065, green: 0.082, blue: 0.103)
    static let panel = Color(red: 0.105, green: 0.129, blue: 0.158)
    static let text = Color(red: 0.92, green: 0.95, blue: 0.98)
    static let muted = Color(red: 0.51, green: 0.58, blue: 0.65)
    static let accent = Color(red: 0.37, green: 0.91, blue: 0.77)
    static let warning = Color(red: 1, green: 0.69, blue: 0.35)
}

private struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? Palette.accent : Palette.text.opacity(0.85))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(configuration.isPressed ? 0.1 : 0.045), in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(configuration.isPressed ? Palette.accent : Palette.muted)
            .frame(width: 29, height: 27)
            .background(Color.white.opacity(configuration.isPressed ? 0.11 : 0.05), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct AccentIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.black)
            .frame(width: 30, height: 27)
            .background(Palette.accent.opacity(configuration.isPressed ? 0.72 : 1), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct DashboardActionStyle: ButtonStyle {
    var active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(active ? .black : Palette.text)
            .padding(.vertical, 10)
            .background(active ? Palette.accent : Palette.background, in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(active ? 0 : 0.07), lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}
