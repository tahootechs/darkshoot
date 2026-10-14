import AppKit
import ScreenCaptureKit

/// Records a screen region to a .mov on the Desktop via SCRecordingOutput.
@MainActor
final class ScreenRecorder: NSObject, SCRecordingOutputDelegate {
    static let shared = ScreenRecorder()
    var onStateChange: () -> Void = {}

    private var stream: SCStream?
    private var outputURL: URL?
    var isRecording: Bool { stream != nil }

    /// `rect` is in the screen's local points, bottom-left origin (AppKit).
    func start(screen: NSScreen, rect: NSRect) async throws {
        guard stream == nil else { return }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let display = content.displays.first(where: { $0.displayID == id }) else { return }
        // Keep our own toast/menu windows out of the video.
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let scale = screen.backingScaleFactor
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX, y: screen.frame.height - rect.maxY, width: rect.width, height: rect.height)
        // H.264 needs even dimensions.
        config.width = Int(rect.width * scale) & ~1
        config.height = Int(rect.height * scale) & ~1
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.showsCursor = true

        let url = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(screenshotFileName().replacingOccurrences(of: "Screenshot", with: "Screen Recording")
                .replacingOccurrences(of: ".png", with: ".mov"))
        let recording = SCRecordingOutputConfiguration()
        recording.outputURL = url
        recording.outputFileType = .mov
        recording.videoCodecType = .h264

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: self))
        try await stream.startCapture()
        self.stream = stream
        outputURL = url
        onStateChange()
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        onStateChange()
        Task {
            do { try await stream.stopCapture() } catch { show(error) }
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor in
            guard let url = outputURL else { return }
            outputURL = nil
            Toast.show("Rekaman tersimpan: \(url.lastPathComponent)")
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: any Error) {
        Task { @MainActor in
            stream = nil
            outputURL = nil
            onStateChange()
            show(error)
        }
    }

    private func show(_ error: Error) {
        NSApp.activate(ignoringOtherApps: true)
        NSAlert(error: error).runModal()
    }
}
