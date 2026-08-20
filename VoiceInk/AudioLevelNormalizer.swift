import Foundation

/// Scales a finished recording to a consistent speech level.
///
/// Recordings are written at whatever level the input device happens to deliver,
/// and that level varies: measured over 781 existing recordings the perceived
/// speech level spans 10.6 dB. The device's own input gain can't close the gap —
/// the built-in microphone tops out at +12 dB and already sits near it.
///
/// Normalizing once, after the file is closed, is deliberate. The input gain does
/// not change mid-recording, so a single gain for the whole file is enough, and
/// one pass avoids the pumping a real-time AGC would add. Applying the gain after
/// Int16 quantization costs nothing measurable here: the acoustic noise floor of
/// these recordings sits around -57 dBFS, some 40 dB above the Int16 quantization
/// floor, so the room — not the converter — sets the noise.
///
/// The reference is the speech level rather than the sample peak. Normalizing by
/// the peak leaves 6.6 dB of spread because a single transient (the hotkey click,
/// a knock on the desk) rides well above the voice; normalizing by the speech
/// level and letting the peak only cap the result flattens the spread to 0.0 dB
/// across those same recordings, without clipping any of them.
enum AudioLevelNormalizer {

    /// Speech level the recording is scaled to. Measured across the existing
    /// recordings this leaves the sample peak near -8 dBFS, so transients keep
    /// their headroom.
    static let targetSpeechLevel: Float = 0.1  // -20 dBFS

    /// Minimum ratio between speech and the noise floor for the recording to be
    /// treated as speech at all. Without it, a recording that captured only room
    /// tone would be lifted by tens of dB into a loud hiss.
    static let minimumSignalToNoise: Float = 3.162  // 10 dB

    /// Gain this close to unity isn't worth rewriting the file for.
    static let deadband: Float = 0.05

    /// Window used to track how the energy evolves, long enough to average out a
    /// pitch period and short enough to separate speech from the gaps in it.
    static let analysisWindowSeconds: Double = 0.02

    private static let fullScale: Float = 32767.0

    /// Gain that brings the speech in `samples` to `targetSpeechLevel`.
    ///
    /// Returns 1.0 when the recording holds no usable speech, so nothing is
    /// amplified into hiss.
    static func gain(for samples: UnsafePointer<Int16>, count: Int, sampleRate: Double) -> Float {
        guard count > 0, sampleRate > 0 else { return 1.0 }

        let windowLength = max(1, Int(sampleRate * analysisWindowSeconds))
        let windowCount = count / windowLength
        guard windowCount >= 20 else { return 1.0 }

        var peak: Float = 0
        var windowLevels = [Float]()
        windowLevels.reserveCapacity(windowCount)

        for window in 0..<windowCount {
            var sum: Double = 0
            let start = window * windowLength
            for i in start..<(start + windowLength) {
                let sample = Float(samples[i]) / fullScale
                sum += Double(sample) * Double(sample)
                let magnitude = abs(sample)
                if magnitude > peak { peak = magnitude }
            }
            windowLevels.append(Float((sum / Double(windowLength)).squareRoot()))
        }

        guard peak > 0 else { return 1.0 }

        windowLevels.sort()
        let speechLevel = windowLevels[min(windowLevels.count - 1, Int(Float(windowLevels.count) * 0.95))]
        let noiseFloor = windowLevels[Int(Float(windowLevels.count) * 0.10)]

        guard speechLevel > 0,
            noiseFloor <= 0 || speechLevel / noiseFloor >= minimumSignalToNoise
        else { return 1.0 }

        // The peak has the final say, so normalizing can never clip.
        return min(targetSpeechLevel / speechLevel, 1.0 / peak)
    }

    /// Byte range of the `data` chunk payload.
    ///
    /// The header is parsed rather than assumed: ExtAudioFile pads it with a
    /// `FLLR` chunk, so the payload starts at 4096 and not at the 44 a minimal
    /// WAV header would imply.
    static func dataChunkRange(in data: Data) -> Range<Int>? {
        let base = data.startIndex
        guard data.count >= 12,
            data[base..<base + 4].elementsEqual(Array("RIFF".utf8)),
            data[base + 8..<base + 12].elementsEqual(Array("WAVE".utf8))
        else { return nil }

        var cursor = 12
        while cursor + 8 <= data.count {
            let identifier = data[base + cursor..<base + cursor + 4]
            var size: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &size) { raw in
                data.copyBytes(to: raw, from: (base + cursor + 4)..<(base + cursor + 8))
            }
            let payload = cursor + 8
            let length = Int(UInt32(littleEndian: size))

            if identifier.elementsEqual(Array("data".utf8)) {
                // Trust the file length over the header: the size is written when
                // the file is closed, so a truncated file would overrun it.
                let end = min(payload + length, data.count)
                guard end > payload else { return nil }
                return payload..<(end - (end - payload) % 2)
            }

            cursor = payload + length + (length & 1)
        }

        return nil
    }

    /// Scales the recording in place. Returns the gain that was applied, or 1.0
    /// when the file was left untouched.
    @discardableResult
    static func normalize(fileAt url: URL, sampleRate: Double) throws -> Float {
        var data = try Data(contentsOf: url)
        guard let range = dataChunkRange(in: data) else { return 1.0 }

        let sampleCount = range.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return 1.0 }

        let gain: Float = data.withUnsafeBytes { raw in
            let samples = raw.baseAddress!.advanced(by: range.lowerBound)
                .assumingMemoryBound(to: Int16.self)
            return Self.gain(for: samples, count: sampleCount, sampleRate: sampleRate)
        }

        guard abs(gain - 1.0) > deadband else { return 1.0 }

        data.withUnsafeMutableBytes { raw in
            let samples = raw.baseAddress!.advanced(by: range.lowerBound)
                .assumingMemoryBound(to: Int16.self)
            for i in 0..<sampleCount {
                let scaled = (Float(samples[i]) * gain).rounded()
                samples[i] = Int16(max(Float(Int16.min), min(scaled, Float(Int16.max))))
            }
        }

        try data.write(to: url, options: .atomic)
        return gain
    }
}
