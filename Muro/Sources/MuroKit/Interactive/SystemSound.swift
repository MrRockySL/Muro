import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// What the Mac is playing, as bands of loudness, for interactive wallpapers
/// that move with sound (issue #59).
///
/// Nothing here runs until a page that asked for sound is on screen and
/// moving, and it stops the moment the last one is paused or goes: the tap is
/// made on the first listener and destroyed on the last. Only how loud each
/// band is leaves this file. The sound itself is never kept, written or sent
/// anywhere.
///
/// macOS 14.2 brought the tap this uses, and asks the person once whether
/// Muro may listen (`NSAudioCaptureUsageDescription`). On an older macOS, or
/// when the answer is no, pages simply hear silence.
public final class SystemSound {
    public static let shared = SystemSound()

    /// Told on the main queue, about forty times a second while sound plays.
    public typealias Listener = ([Float]) -> Void

    private var listeners: [UUID: Listener] = [:]
    /// The listeners that asked for listening to start. The rest only hear
    /// what is already being listened to.
    private var starters = Set<UUID>()
    private var tap: AnyObject?

    private init() {}

    public static var isAvailable: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    /// Adds a listener. Call on the main queue.
    ///
    /// `starting` is true for an interactive wallpaper on the desktop: Muro
    /// begins to listen for it, which is when macOS asks the person whether
    /// it may. It is false for a wallpaper only being looked at in the
    /// gallery, which hears the sound if Muro is listening already and never
    /// makes macOS ask (owner, 2026-11-13: it asks only when somebody puts an
    /// interactive wallpaper on).
    public func add(starting: Bool = true, _ listener: @escaping Listener) -> UUID {
        let id = UUID()
        listeners[id] = listener
        if starting {
            starters.insert(id)
            if starters.count == 1 { start() }
        }
        return id
    }

    /// Removes a listener. Listening stops with the last one that started it.
    /// Call on the main queue.
    public func remove(_ id: UUID) {
        guard listeners.removeValue(forKey: id) != nil else { return }
        if starters.remove(id) != nil, starters.isEmpty { stop() }
    }

    private func start() {
        guard #available(macOS 14.2, *) else { return }
        // The tap by itself first. A Mac that will not run it that way gets
        // it beside the sound device it plays through.
        for alone in [true, false] {
            let tap = SoundTap()
            tap.onBands = { [weak self] bands in
                DispatchQueue.main.async {
                    guard let self else { return }
                    for listener in self.listeners.values { listener(bands) }
                }
            }
            if let problem = tap.start(alone: alone) {
                EngineLog.log("sound: could not listen (\(problem))")
                tap.stop()
                continue
            }
            EngineLog.log("sound: listening")
            self.tap = tap
            return
        }
    }

    private func stop() {
        guard #available(macOS 14.2, *), let tap = tap as? SoundTap else { return }
        tap.stop()
        self.tap = nil
        EngineLog.log("sound: stopped listening")
    }
}

/// Splits a block of samples into bands, low notes first.
final class SoundSpectrum {
    static let size = 2048
    private let log2n = vDSP_Length(11)
    private let setup: FFTSetup
    private var window: [Float]
    private var input: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]

    init() {
        let n = Self.size
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        input = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imaginary = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    /// `samples` holds `size` values. Each band comes back 0 to 1.
    func bands(_ samples: [Float], sampleRate: Float, count: Int) -> [Float] {
        let n = Self.size
        vDSP_vmul(samples, 1, window, 1, &input, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(
                    realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!
                )
                input.withUnsafeBufferPointer { pointer in
                    pointer.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvabs(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }
        return Self.bands(magnitudes: magnitudes, sampleRate: sampleRate, count: count)
    }

    /// Bands spaced the way notes are, 40 Hz to 16 kHz, each the loudest
    /// frequency inside it on a decibel scale. Quiet treble still shows: music
    /// carries far less energy up there, so the top bands get a lift.
    static func bands(magnitudes: [Float], sampleRate: Float, count: Int) -> [Float] {
        let n = magnitudes.count * 2
        let low: Float = 40
        let high: Float = min(16_000, sampleRate / 2 - 100)
        let binWidth = sampleRate / Float(n)
        var out = [Float](repeating: 0, count: count)
        guard high > low, count > 0 else { return out }
        for band in 0..<count {
            let from = low * pow(high / low, Float(band) / Float(count))
            let to = low * pow(high / low, Float(band + 1) / Float(count))
            let first = min(magnitudes.count - 1, max(1, Int(from / binWidth)))
            let last = min(magnitudes.count - 1, max(first, Int(to / binWidth)))
            var peak: Float = 0
            for bin in first...last { peak = max(peak, magnitudes[bin]) }
            // zrip gives twice the amplitude times n / 2.
            let amplitude = peak / Float(n)
            let decibels = 20 * log10(amplitude + 1e-7)
            let lift = Float(band) / Float(count) * 16
            out[band] = max(0, min(1, (decibels + lift + 60) / 50))
        }
        return out
    }
}

/// The Core Audio tap: everything the Mac plays, mixed down, never changed.
@available(macOS 14.2, *)
final class SoundTap {
    var onBands: (([Float]) -> Void)?

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "com.mrrockysl.muro.sound", qos: .userInitiated)
    private var recent = [Float](repeating: 0, count: SoundSpectrum.size)
    private var ordered = [Float](repeating: 0, count: SoundSpectrum.size)
    private var writeIndex = 0
    private var lastEmit = DispatchTime.now()
    /// Blocks in a row with nothing in them. Once the window is all silence
    /// there is nothing to measure, and zeros are handed on without a
    /// transform.
    private var quietFrames = 0
    private let spectrum = SoundSpectrum()
    private var sampleRate: Float = 48_000

    func start(alone: Bool) -> String? {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        description.name = "Muro"
        var tap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr else { return "tap \(status)" }
        tapID = tap

        // The tap alone, with no sound device beside it, so listening never
        // keeps the Mac's speakers running.
        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Muro Sound",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [] as [Any],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        if !alone {
            guard let output = Self.defaultOutputUID() else { return "no sound device" }
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = output
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: output]]
        }
        var device = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device)
        guard status == noErr else { return "device \(status)" }
        deviceID = device

        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr,
           format.mSampleRate > 0 {
            sampleRate = Float(format.mSampleRate)
        }

        status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, queue) { [weak self] _, input, _, _, _ in
            self?.take(input)
        }
        guard status == noErr, let procID else { return "listener \(status)" }
        status = AudioDeviceStart(deviceID, procID)
        return status == noErr ? nil : "start \(status)"
    }

    func stop() {
        if let procID, deviceID != kAudioObjectUnknown {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        deviceID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
        // Anything still on its way from the queue is let finish first.
        queue.sync {}
    }

    private static func defaultOutputUID() -> String? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        ) == noErr else { return nil }
        var uid: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        address.mSelector = kAudioDevicePropertyDeviceUID
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &uid) == noErr,
              let uid
        else { return nil }
        return uid.takeRetainedValue() as String
    }

    private func take(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard buffers.count > 0, let data = buffers[0].mData else { return }
        let channels = max(1, Int(buffers[0].mNumberChannels))
        let frames = Int(buffers[0].mDataByteSize) / (MemoryLayout<Float32>.size * channels)
        guard frames > 0 else { return }
        let left = data.bindMemory(to: Float32.self, capacity: frames * channels)
        let right: UnsafeMutablePointer<Float32>? = (channels == 1 && buffers.count > 1)
            ? buffers[1].mData?.bindMemory(to: Float32.self, capacity: frames)
            : nil
        var loudest: Float = 0
        for frame in 0..<frames {
            var value: Float = 0
            if channels > 1 {
                for channel in 0..<channels { value += left[frame * channels + channel] }
                value /= Float(channels)
            } else if let right {
                value = (left[frame] + right[frame]) / 2
            } else {
                value = left[frame]
            }
            loudest = max(loudest, abs(value))
            recent[writeIndex] = value
            writeIndex = (writeIndex + 1) % recent.count
        }
        quietFrames = loudest < 1e-5 ? quietFrames + frames : 0

        let now = DispatchTime.now()
        guard now.uptimeNanoseconds - lastEmit.uptimeNanoseconds > 24_000_000 else { return }
        lastEmit = now
        if quietFrames >= recent.count {
            onBands?([Float](repeating: 0, count: InteractiveBridge.bandCount))
            return
        }
        let split = recent.count - writeIndex
        ordered.replaceSubrange(0..<split, with: recent[writeIndex...])
        ordered.replaceSubrange(split..., with: recent[..<writeIndex])
        onBands?(spectrum.bands(ordered, sampleRate: sampleRate, count: InteractiveBridge.bandCount))
    }
}
