import AVFoundation

public enum MediaFormat: String, CaseIterable {
    case mp4, mov, m4a, mp3, wav, aiff, flac, gif, webm

    public var title: String { rawValue.uppercased() }
    public var isAudio: Bool { [.m4a, .mp3, .wav, .aiff, .flac].contains(self) }

    /// Formats AVFoundation or afconvert handle without extra installs.
    public var isNative: Bool { [.mp4, .mov, .m4a, .wav, .aiff].contains(self) }

    public static func of(_ url: URL) -> MediaFormat? {
        switch url.pathExtension.lowercased() {
        case "aif": return .aiff
        case let e: return MediaFormat(rawValue: e)
        }
    }
}

public enum MediaEngine {
    public static func convert(_ src: URL, to format: MediaFormat, out: URL, progress: @escaping ProgressHandler) async throws {
        switch format {
        case .mp4, .mov, .m4a:
            try await export(src, to: out, format: format, progress: progress)
        case .wav, .aiff:
            if let afconvert = ExternalTools.afconvert, FileKind.of(src) == .audio {
                let (file, data) = format == .wav ? ("WAVE", "LEI16") : ("AIFF", "BEI16")
                try await ExternalTools.run(afconvert, ["-f", file, "-d", data, src.path, out.path])
            } else {
                try await ffmpegConvert(src, to: format, out: out, progress: progress)
            }
        default:
            try await ffmpegConvert(src, to: format, out: out, progress: progress)
        }
    }

    private static func ffmpegConvert(_ src: URL, to format: MediaFormat, out: URL, progress: @escaping ProgressHandler) async throws {
        guard let ffmpeg = ExternalTools.ffmpeg else {
            throw ActionError("\(format.title) needs ffmpeg. Install with: brew install ffmpeg")
        }
        var args = ["-nostdin", "-loglevel", "error", "-i", src.path]
        switch format {
        case .gif: args += ["-vf", "fps=12,scale='min(640,iw)':-2:flags=lanczos", "-loop", "0"]
        case .mp3: args += ["-vn", "-q:a", "2"]
        case .wav, .aiff, .flac: args += ["-vn"]
        case .webm: args += ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", "32", "-c:a", "libopus"]
        default: break
        }
        args.append(out.path)
        await progress(0.1)
        try await ExternalTools.run(ffmpeg, args)
    }

    private static func export(_ src: URL, to out: URL, format: MediaFormat, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: src)
        let preset = format == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw ActionError("This file can't be exported as \(format.title).")
        }
        let type: AVFileType = format == .mp4 ? .mp4 : format == .mov ? .mov : .m4a
        session.outputURL = out
        session.outputFileType = type

        let poll = Task { @MainActor in
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
        defer { poll.cancel() }
        await withTaskCancellationHandler {
            await session.export()
        } onCancel: {
            session.cancelExport()
        }
        if session.status == .cancelled { throw CancellationError() }
        if let error = session.error { throw ActionError(error.localizedDescription) }
    }
}
