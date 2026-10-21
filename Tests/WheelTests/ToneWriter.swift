import AVFoundation

enum ToneWriter {
    /// Writes one second of a 440 Hz sine wave.
    static func write(to url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100,
                                                               AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = sin(Float(i) * 2 * .pi * 440 / 44_100) * 0.3 }
        try file.write(from: buffer)
    }
}
