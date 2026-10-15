import AppKit
import AVFoundation
import ScreenCaptureKit

// Captures the windows of one process with ScreenCaptureKit: composited together (so menus and popovers come along),
// without whatever lies in front of or behind them, cropped to the largest window. `all` crops to every window
// instead, for a menu that reaches past the window's edge, and prints where the main window sits in the picture.
// The app doesn't need to be in front.
//   capture shot <pid> <out.png>
//   capture all <pid> <out.png>
//   capture rec <pid> <out.mov> <seconds>
let args = CommandLine.arguments
guard args.count >= 4, let pid = pid_t(args[2]) else {
    print("usage: capture shot|all <pid> <out.png> | capture rec <pid> <out.mov> <seconds>")
    exit(2)
}
let mode = args[1]
let out = URL(fileURLWithPath: args[3])

func setup() async throws -> (SCContentFilter, SCStreamConfiguration) {
    let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
    let windows = content.windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen && $0.frame.width > 2 }
    guard let main = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
          let display = content.displays.first(where: { $0.frame.intersects(main.frame) }) else {
        throw NSError(domain: "capture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No window of process \(pid) on a display (is the screen asleep?)"])
    }
    let filter = SCContentFilter(display: display, including: windows)
    let config = SCStreamConfiguration()
    let scale = CGFloat(filter.pointPixelScale)
    var rect = main.frame
    if mode == "all" {
        rect = windows.reduce(main.frame) { $0.union($1.frame) }.intersection(display.frame)
        print("window \(Int(main.frame.minX - rect.minX)) \(Int(main.frame.minY - rect.minY)) \(Int(main.frame.width)) \(Int(main.frame.height))")
    }
    rect.origin.x -= display.frame.origin.x
    rect.origin.y -= display.frame.origin.y
    config.sourceRect = rect
    config.width = Int(rect.width * scale)
    config.height = Int(rect.height * scale)
    config.showsCursor = false
    config.backgroundColor = .clear
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.colorSpaceName = CGColorSpace.sRGB
    return (filter, config)
}

final class RecordingDelegate: NSObject, SCRecordingOutputDelegate {
    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        print("recording failed: \(error)")
        exit(1)
    }
}

Task {
    do {
        let (filter, config) = try await setup()
        if mode == "shot" || mode == "all" {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!.write(to: out)
        } else {
            config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            config.queueDepth = 8
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            let recording = SCRecordingOutputConfiguration()
            recording.outputURL = out
            recording.outputFileType = .mov
            recording.videoCodecType = .hevc
            let delegate = RecordingDelegate()
            try stream.addRecordingOutput(SCRecordingOutput(configuration: recording, delegate: delegate))
            try await stream.startCapture()
            print("recording")  // the caller waits for this line before it starts the scene
            fflush(stdout)
            try await Task.sleep(for: .seconds(Double(args[4]) ?? 4))
            try await stream.stopCapture()
            try await Task.sleep(for: .milliseconds(500))
            _ = delegate
        }
        exit(0)
    } catch {
        print("capture: \(error.localizedDescription)")
        exit(1)
    }
}
RunLoop.main.run()
