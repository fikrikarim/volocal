# Android Audio & Echo Cancellation Research

## iOS Baseline

- Single `AVAudioEngine` for both mic input and speaker output
- Voice Processing AEC (`setVoiceProcessingEnabled(true)`) -- hardware echo cancellation
- Mic stays open during TTS playback for barge-in
- `AudioSession` configured for `.playAndRecord` with `.voiceChat` mode
- Input tap captures mic audio as PCM frames for STT
- `PlayerNode` plays TTS audio frames

---

## 1. Audio APIs for Simultaneous Capture + Playback

### Oboe (C++) -- RECOMMENDED

**Repository**: [github.com/google/oboe](https://github.com/google/oboe)

- Google's official C++ audio library
- Wraps AAudio (API 27+) with automatic fallback to OpenSL ES (API 16+)
- Lowest possible latency across widest device range
- `FullDuplexStream` helper for synchronized input+output
- Audio callbacks run on high-priority SCHED_FIFO thread (priority 2-3)

**Reference implementations**:
- [Oboe LiveEffect Sample](https://github.com/google/oboe/blob/main/samples/LiveEffect/README.md) -- full-duplex loopback
- [Oboe FullDuplexStream Wiki](https://github.com/google/oboe/wiki/Using-FullDuplexStream-for-Synchronized-IO)

### AAudio (C)
- Native API, Android 8.0+ (API 27)
- Oboe uses AAudio when available; no reason to use directly

### AudioTrack + AudioRecord (Java/Kotlin)
- Higher-level APIs; simpler but higher latency (~50-100ms vs ~20ms for native)
- Easier `AcousticEchoCanceler` integration (direct session ID access)
- Reasonable fallback if C++ complexity is undesirable

### OpenSL ES (C)
- Cross-platform but **deprecated** in favor of AAudio/Oboe
- Oboe falls back to this on older devices automatically

### Recommendation

**Oboe with Kotlin/JNI bridge**. UI and pipeline in Kotlin, all audio I/O in C++ via Oboe.

---

## 2. Echo Cancellation

### The Core Challenge

iOS: `setVoiceProcessingEnabled(true)` "just works" across all Apple devices.
Android: AEC quality is **device-dependent** because each OEM implements their own audio HAL.

### Option A: Platform AEC via VoiceCommunication Preset -- TRY FIRST

```cpp
// Oboe input stream
inputBuilder.setInputPreset(oboe::InputPreset::VoiceCommunication);
outputBuilder.setUsage(oboe::Usage::VoiceCommunication);
```

**Pros**: Zero additional code; uses hardware-accelerated AEC when available.

**Cons**:
- Quality varies significantly across OEMs
- Some devices (Samsung Galaxy A15) produce blank audio with VoiceCommunication ([Oboe Issue #2123](https://github.com/google/oboe/issues/2123))
- Forces mono input on many devices
- Prevents exclusive mode / low-latency path on some devices
- Historical issues: Galaxy Tab 3, Galaxy S3/S4, Nexus 4/5/7

**Critical caveat**: Using AudioEffects with Oboe prevents the low-latency path. Stream "is not Exclusive anymore" ([Oboe Issue #951](https://github.com/google/oboe/issues/951)).

### Option B: AcousticEchoCanceler (Java AudioEffect API)

```kotlin
val audioRecord = AudioRecord(...)
val sessionId = audioRecord.audioSessionId
if (AcousticEchoCanceler.isAvailable()) {
    val aec = AcousticEchoCanceler.create(sessionId)
    aec.enabled = true
}
```

Same device-fragmentation problems as Option A (same underlying implementation). Does NOT work reliably with Oboe streams.

### Option C: WebRTC AEC (Software Fallback) -- SAFETY NET

For devices where platform AEC is inadequate:

- **AECm**: Lightweight, designed for mobile
- **AEC3**: Heavier, higher quality
- Libraries: [android-webrtc-aecm](https://github.com/theeasiestway/android-webrtc-aecm), [Android-Audio-Processing-Using-WebRTC](https://github.com/mail2chromium/Android-Audio-Processing-Using-WebRTC)

**Implementation**:
1. Capture mic audio from Oboe input (no platform AEC)
2. Capture TTS output samples as "far-end" reference signal
3. Feed both into WebRTC AECm for clean mic audio
4. Send cleaned audio to STT

**Pros**: Consistent behavior across all devices. Battle-tested in VoIP apps.

**Cons**: Additional ~2-5ms per frame. Must maintain correct alignment between reference and mic signals.

### Recommended Strategy: Tiered AEC

```
1. Try platform AEC (VoiceCommunication preset)
2. At runtime, test AEC quality with short loopback check
3. If quality is poor, fall back to WebRTC AECm
4. Maintain device blocklist/allowlist over time
```

---

## 3. Barge-In Implementation

### iOS Pattern (What We're Replicating)

- `onSpeechDetected` fires when STT sees 2+ words of partial transcript
- Calls `interrupt()` which cancels TTS via `playerNode.stop()`
- Mic is **never** closed during TTS playback; VP AEC filters out speaker

### Android Equivalent

**Step 1: Keep mic open during playback**

Run two separate Oboe streams (input + output) simultaneously. Input stream uses `InputPreset::VoiceCommunication` for AEC.

**Step 2: Detect user speech during AI playback**

Use VAD on AEC-cleaned mic signal:

- **[android-vad](https://github.com/gkonovalov/android-vad)**: Android-native VAD library
  - **Silero VAD** (DNN, ONNX Runtime): 16-bit mono PCM at 16 kHz, frame size 512, <1ms per chunk
  - **WebRTC VAD** (GMM): 158 KB, extremely fast
  - Configurable silence duration (default 300ms) and speech threshold (default 50ms)

**Step 3: Cancel playback mid-stream**

```kotlin
fun stopPlayback() {
    outputStream.requestStop()   // Stop Oboe output
    clearPendingBuffers()        // Clear queued TTS frames
    outputStream.requestStart()  // Restart for next utterance
    isSpeaking = false
}
```

**Step 4: Latency budget**

| Component | Latency |
|-----------|---------|
| Mic capture (Oboe) | 5-10ms |
| AEC processing | 2-5ms |
| VAD detection (Silero) | <1ms |
| Speech-to-words threshold | 200-500ms (2+ words) |
| Playback stop | <5ms |
| **Total barge-in response** | **~250-550ms** |

Comparable to iOS implementation. Bottleneck is the same: waiting for enough speech to confirm it's intentional.

---

## 4. Audio Routing & Session Management

### Audio Focus

```kotlin
val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
    .setAudioAttributes(AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
        .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
        .build())
    .setOnAudioFocusChangeListener { focusChange ->
        when (focusChange) {
            AudioManager.AUDIOFOCUS_LOSS -> pausePipeline()
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> pausePipeline()
            AudioManager.AUDIOFOCUS_GAIN -> resumePipeline()
        }
    }
    .build()
audioManager.requestAudioFocus(focusRequest)
```

Use `AUDIOFOCUS_GAIN` (not `GAIN_TRANSIENT_MAY_DUCK` which has 15-second limit).

### Bluetooth / Audio Routing (Android 12+)

```kotlin
// Replace deprecated startBluetoothSco()
val devices = audioManager.availableCommunicationDevices
val bleHeadset = devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLE_HEADSET }
    ?: devices.firstOrNull { it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO }
bleHeadset?.let { audioManager.setCommunicationDevice(it) }

// Cleanup
audioManager.clearCommunicationDevice()
```

### Phone Call Interruption

```kotlin
telephonyManager.registerTelephonyCallback(executor, object : TelephonyCallback(),
    TelephonyCallback.CallStateListener {
    override fun onCallStateChanged(state: Int) {
        if (state != TelephonyManager.CALL_STATE_IDLE) {
            pausePipeline()
        }
    }
})
```

### Background Audio

Android kills audio streams when app backgrounds unless running foreground service with `android.permission.FOREGROUND_SERVICE_MICROPHONE` (Android 14+).

---

## 5. Known Challenges

### Audio Latency Fragmentation

- Native sample rate: **48 kHz** on most devices
- Round-trip latency: **~10ms** (Pixel, best case) to **~200ms+** (budget devices)
- Two phones with identical SoC may differ due to vendor audio HAL

### AEC Quality Variance -- BIGGEST RISK

Known problem devices:
- Samsung Galaxy Tab 3, Galaxy S3/S4, Galaxy Note 2/3
- Nexus 4, Nexus 5, Nexus 7
- Some Galaxy A-series (blank audio with VoiceCommunication)
- Budget Xiaomi/Redmi often have poor AEC

### Sample Rate Compatibility

App needs 16 kHz for STT and 24 kHz for TTS, but devices are natively 48 kHz.

**Using non-native rates forces resampling, preventing FastMixer low-latency path.**

**Recommended approach**:
1. Run Oboe streams at native rate (48 kHz)
2. Downsample 48k->16k for STT (Oboe's built-in resampler or [AndroidResampler](https://github.com/Nailik/AndroidResampler))
3. Upsample 24k->48k for TTS output (clean 1:2 ratio, minimal artifacts)

### Thread Priority

- Oboe callbacks already run on SCHED_FIFO (real-time priority)
- **Never** do allocations, locks, file I/O, or JNI calls in audio callback
- Use lock-free ring buffers between audio thread and processing threads

---

## 6. Recommended Architecture

```
+-----------------------------------------------------+
|                 Kotlin Layer                          |
|  VoicePipeline  |  LLM Manager  |  UI (Compose)     |
|       | JNI                                          |
+-------+----------------------------------------------+
|       v           C++ Layer                          |
|  +-----------------------------------------------+   |
|  |         AudioEngine (C++)                     |   |
|  |  +-------------+  +----------------+          |   |
|  |  | Oboe Input  |  | Oboe Output    |          |   |
|  |  | 48kHz, mono |  | 48kHz, mono    |          |   |
|  |  | VoiceComm   |  | VoiceComm      |          |   |
|  |  +------+------+  +--------+-------+          |   |
|  |         |                   |                  |   |
|  |    +----v----+         +----v----+             |   |
|  |    |Resample |         |Resample |             |   |
|  |    |48k->16k |         |24k->48k |             |   |
|  |    +----+----+         +----+----+             |   |
|  |         |                   |                  |   |
|  |    +----v----+         +----v----+             |   |
|  |    |Lock-free|         |Lock-free|             |   |
|  |    |RingBuf  |         |RingBuf  |             |   |
|  |    |(to STT) |         |(from TTS|             |   |
|  |    +---------+         +---------+             |   |
|  |                                                |   |
|  |  +--------------------+                        |   |
|  |  | WebRTC AECm        | <- fallback only       |   |
|  |  +--------------------+                        |   |
|  +-----------------------------------------------+   |
|                                                       |
|  +----------+  +----------+  +----------+             |
|  |  STT     |  |  VAD     |  |   TTS    |             |
|  |(sherpa-  |  |(Silero/  |  |(sherpa-  |             |
|  | onnx)    |  | android- |  | onnx)    |             |
|  |          |  | vad)     |  |          |             |
|  +----------+  +----------+  +----------+             |
+-------------------------------------------------------+
```

### Key Decisions

1. **Two separate Oboe streams** (not FullDuplexStream). Input goes to STT, output comes from TTS asynchronously.
2. **Run at native 48 kHz**. Resample in software. Keeps FastMixer low-latency path.
3. **Platform AEC first, WebRTC fallback**. Keep reference copy of output signal for software AEC.
4. **Silero VAD for barge-in**. When speech detected >50ms, trigger interrupt.
5. **Lock-free ring buffers** between Oboe callbacks and processing threads.

---

## 7. iOS to Android Mapping

| iOS (Current) | Android (Target) |
|--------------|------------------|
| `AVAudioEngine` | Oboe (C++ via JNI) |
| `setVoiceProcessingEnabled(true)` | `InputPreset::VoiceCommunication` + `Usage::VoiceCommunication` |
| `.playAndRecord` + `.voiceChat` | `AUDIOFOCUS_GAIN` + `MODE_IN_COMMUNICATION` |
| `inputNode.installTap()` | Oboe input callback -> ring buffer -> STT thread |
| `AVAudioPlayerNode.scheduleBuffer()` | Write TTS samples to Oboe output ring buffer |
| `playerNode.stop()` (barge-in) | `outputStream.requestStop()` + clear buffers |
| Hardware AEC (consistent) | Platform AEC (inconsistent) + WebRTC AECm fallback |
| 24 kHz TTS native | 24 kHz TTS -> resample to 48 kHz |
| VP handles mic during playback | VoiceCommunication preset (platform-dependent) |

---

## 8. AEC Risk Mitigation

1. Build WebRTC AECm fallback from day one
2. Test on at least 5-6 device categories (Pixel, Samsung flagship, Samsung budget, Xiaomi, OnePlus, older API 27)
3. Add runtime AEC quality detection (play known tone, capture mic, measure residual echo)
4. Maintain device-specific configuration database over time

---

## Sources

- [Google Oboe](https://github.com/google/oboe)
- [Oboe FullDuplexStream Wiki](https://github.com/google/oboe/wiki/Using-FullDuplexStream-for-Synchronized-IO)
- [Oboe TechNote_Effects](https://github.com/google/oboe/wiki/TechNote_Effects)
- [Oboe TechNote_BluetoothAudio](https://github.com/google/oboe/wiki/TechNote_BluetoothAudio)
- [Oboe Issue #951](https://github.com/google/oboe/issues/951)
- [Oboe Issue #2123](https://github.com/google/oboe/issues/2123)
- [AcousticEchoCanceler API](https://developer.android.com/reference/android/media/audiofx/AcousticEchoCanceler)
- [Android Audio Latency](https://source.android.com/docs/core/audio/latency/latency)
- [Android Audio Focus](https://developer.android.com/media/optimize/audio-focus)
- [Avoiding Priority Inversion](https://source.android.com/docs/core/audio/avoiding_pi)
- [android-vad](https://github.com/gkonovalov/android-vad)
- [android-webrtc-aecm](https://github.com/theeasiestway/android-webrtc-aecm)
- [Android-Audio-Processing-Using-WebRTC](https://github.com/mail2chromium/Android-Audio-Processing-Using-WebRTC)
- [AndroidResampler](https://github.com/Nailik/AndroidResampler)
- [Oboe LiveEffect Sample](https://github.com/google/oboe/blob/main/samples/LiveEffect/README.md)
