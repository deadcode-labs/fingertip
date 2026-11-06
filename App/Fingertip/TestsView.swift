//
//  TestsView.swift
//  Fingertip
//
//  The "Tests" window: the tests the MCP saved under `TestSession.directory`, and for
//  one of them its verdict, video and steps with the screen after each step. Read-only;
//  everything it shows comes from `TestLibrary`.
//

import AVKit
import FingertipCore
import SwiftUI

struct TestsView: View {
    @State private var tests: [TestSummary] = []
    @State private var selection: URL?
    @State private var loading = false

    private var selected: TestSummary? {
        tests.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            TestListView(tests: tests, selection: $selection, loading: loading)
                // A max, so a width AppKit restored from a bad session can't swallow the detail.
                .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 420)
        } detail: {
            Group {
                if let selected {
                    // One identity per test, so the picked step and pane don't carry over.
                    TestDetailView(test: selected)
                        .id(selected.id)
                } else {
                    ContentUnavailableView(
                        "No Test Selected",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Choose a test from the list to see its video and steps.")
                    )
                }
            }
            .frame(minWidth: 600)
        }
        .toolbar {
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await reload() }
                }
                .keyboardShortcut("r")
                .disabled(loading)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .task { await reload() }
    }

    private func reload() async {
        loading = true
        defer { loading = false }
        let directory = TestSession.directory
        let fresh = await Task.detached(priority: .userInitiated) {
            TestLibrary.list(in: directory)
        }.value
        tests = fresh
        if let selection, !fresh.contains(where: { $0.id == selection }) {
            self.selection = nil
        }
    }
}

// MARK: - List

private struct TestListView: View {
    let tests: [TestSummary]
    @Binding var selection: URL?
    let loading: Bool

    var body: some View {
        List(tests, selection: $selection) { test in
            TestRow(test: test)
        }
        .overlay {
            if tests.isEmpty && !loading {
                ContentUnavailableView(
                    "No Tests",
                    systemImage: "tray",
                    description: Text("Tests the MCP saves with connect(test:) appear here.")
                )
            }
        }
    }
}

private struct TestRow: View {
    let test: TestSummary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VerdictMark(verdict: test.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(test.name)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let started = test.started {
                        Text(started, format: .dateTime.day().month().hour().minute())
                    }
                    if let target = test.target {
                        Text(target).lineLimit(1)
                    }
                    if let duration = test.duration {
                        Text(TestFormat.duration(duration))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if let problem = test.problem {
                    Text(problem)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct VerdictMark: View {
    let verdict: TestSummary.Verdict
    var showsTitle = false

    var body: some View {
        if showsTitle {
            Label(title, systemImage: symbol)
                .foregroundStyle(color)
        } else {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .help(title)
                .accessibilityLabel(title)
        }
    }

    private var title: String {
        switch verdict {
        case .passed: String(localized: "Passed")
        case .failed: String(localized: "Failed")
        case .none: String(localized: "No verdict")
        case .inProgress: String(localized: "In progress")
        case .unknown: String(localized: "Unreadable test.json")
        }
    }

    private var symbol: String {
        switch verdict {
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        case .none: "minus.circle"
        case .inProgress: "clock"
        case .unknown: "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch verdict {
        case .passed: .green
        case .failed: .red
        case .none: .secondary
        case .inProgress: .blue
        case .unknown: .orange
        }
    }
}

// MARK: - Detail

private struct TestDetailView: View {
    let test: TestSummary
    @State private var steps: [TestStep] = []
    @State private var stepSelection: Int?
    @State private var pane = Pane.video

    private enum Pane { case video, step }

    private var selectedStep: TestStep? {
        steps.first { $0.id == stepSelection }
    }

    // Fixed stacks rather than `VSplitView`/`HSplitView`: inside a `NavigationSplitView`
    // those took their children's ideal sizes and spilled the detail past the window.
    var body: some View {
        VStack(spacing: 0) {
            TestHeader(test: test)
                .padding()
            Divider()
            HStack(spacing: 0) {
                StepList(test: test, steps: steps, selection: $stepSelection)
                    .frame(width: 320)
                Divider()
                VStack(spacing: 0) {
                    Picker("View", selection: $pane) {
                        Text("Video").tag(Pane.video)
                        Text("Step").tag(Pane.step)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .padding(8)
                    Divider()
                    // Fills the height, so an empty state doesn't pull the picker down.
                    Group {
                        switch pane {
                        case .video:
                            // Keyed on `ended`: a player opened mid-test holds an unfinished
                            // file, so it reloads once a refresh shows the test closed.
                            RecordingPlayer(recording: test.recording, error: test.recordingError)
                                .id(test.ended)
                        case .step:
                            if let selectedStep {
                                StepDetail(step: selectedStep)
                            } else {
                                ContentUnavailableView(
                                    "No Step Selected",
                                    systemImage: "rectangle.on.rectangle",
                                    description: Text("Choose a step to see its screen and result.")
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // A refreshed summary differs (new `ended`, verdict…), so this also reloads the steps.
        .task(id: test) { await loadSteps() }
        .onChange(of: stepSelection) { _, step in
            if step != nil { pane = .step }
        }
    }

    private func loadSteps() async {
        let test = test
        let fresh = await Task.detached(priority: .userInitiated) {
            TestLibrary.steps(of: test)
        }.value
        steps = fresh
        if let stepSelection, !fresh.contains(where: { $0.id == stepSelection }) {
            self.stepSelection = nil
        }
    }
}

private struct TestHeader: View {
    let test: TestSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(test.name)
                    .font(.title2.bold())
                    .textSelection(.enabled)
                VerdictMark(verdict: test.verdict, showsTitle: true)
                    .font(.headline)
                Spacer()
                if test.hasJevRuns {
                    Button("Jev Runs in Finder") { reveal(test.jevDirectory) }
                }
                Button("Show in Finder") { reveal(test.folder) }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Target", test.target ?? "—")
                row("Started", test.started.map(TestFormat.date) ?? "—")
                row("Ended", test.ended.map(TestFormat.date) ?? String(localized: "not finished"))
                if let duration = test.duration {
                    row("Duration", TestFormat.duration(duration))
                }
            }
            .font(.callout)

            if let notes = test.notes, !notes.isEmpty {
                Text(notes)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let problem = test.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let error = test.recordingError {
                Label("Recording error: \(error)", systemImage: "video.slash")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct RecordingPlayer: View {
    let recording: URL?
    let error: String?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                PlayerView(player: player)
            } else {
                ContentUnavailableView(
                    "No Video",
                    systemImage: "video.slash",
                    description: Text(error == nil ? "This test has no recording.mov." : "The recording failed.")
                )
            }
        }
        .task(id: recording) {
            player?.pause()
            player = recording.map { AVPlayer(url: $0) }
        }
        .onDisappear { player?.pause() }
    }
}

/// AppKit's `AVPlayerView`, not SwiftUI's `VideoPlayer`: on macOS 27.0 instantiating
/// `VideoPlayer`'s generic metadata in `_AVKit_SwiftUI` aborts the app
/// (`getSuperclassMetadata` fatal error) as soon as the detail appears.
private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        // Its intrinsic size is the video's pixel size (a Retina recording is thousands of
        // points wide); left as the ideal size, it widens the whole detail past the window.
        for orientation in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            view.setContentHuggingPriority(.defaultLow, for: orientation)
            view.setContentCompressionResistancePriority(.defaultLow, for: orientation)
        }
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }

    /// Takes whatever it is offered; the video letterboxes inside.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: AVPlayerView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 480, height: proposal.height ?? 260)
    }
}

private struct StepList: View {
    let test: TestSummary
    let steps: [TestStep]
    @Binding var selection: Int?

    var body: some View {
        List(steps, selection: $selection) { step in
            StepRow(step: step)
        }
        .overlay {
            if steps.isEmpty {
                ContentUnavailableView(
                    "No Steps",
                    systemImage: "list.number",
                    description: Text(test.hasTrace ? "trace.jsonl is empty." : "trace.jsonl is missing.")
                )
            }
        }
    }
}

private struct StepRow: View {
    let step: TestStep

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(step.id + 1)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if let problem = step.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text(step.tool).bold()
                }
                Spacer(minLength: 4)
                if let code = step.errorCode {
                    Text(code)
                        .font(.caption.monospaced())
                        .foregroundStyle(.red)
                }
                if let ms = step.milliseconds {
                    Text("\(ms) ms")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            let detail = step.problem == nil ? argumentsText : step.raw
            if !detail.isEmpty {
                Text(detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }

    private var argumentsText: String {
        step.arguments.map { "\($0.key): \($0.value)" }.joined(separator: "  ")
    }
}

private struct StepDetail: View {
    let step: TestStep
    @State private var image: NSImage?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(8)
                } else if step.screenMissing {
                    ContentUnavailableView(
                        "Screen Missing",
                        systemImage: "photo.badge.exclamationmark",
                        description: Text("\(step.screenName ?? "") isn’t in the test’s folder.")
                    )
                } else if step.screen == nil {
                    ContentUnavailableView("No Screen", systemImage: "photo")
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if let at = step.at {
                        Text(TestFormat.date(at))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !step.arguments.isEmpty {
                        ForEach(step.arguments, id: \.key) { argument in
                            Text("\(argument.key): \(argument.value)")
                        }
                        .font(.callout.monospaced())
                    }
                    Text(step.problem == nil ? step.result : step.raw)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .textSelection(.enabled)
                .padding()
            }
            .frame(height: 200)
        }
        .task(id: step.screen) { await loadImage() }
    }

    private func loadImage() async {
        image = nil
        guard let url = step.screen else { return }
        let data = await Task.detached(priority: .userInitiated) {
            try? Data(contentsOf: url)
        }.value
        image = data.flatMap(NSImage.init(data:))
    }
}

// MARK: - Formatting

private enum TestFormat {
    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        Duration.seconds(seconds.rounded())
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }
}
