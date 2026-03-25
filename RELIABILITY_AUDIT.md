# Locus Voice Pipeline - Reliability Audit

Audited: 2026-03-25
Files reviewed: all 18 Swift source files

---

## CRITICAL (will cause crashes or stuck states)

### 1. VoicePipeline: Polling loop in `handleUtterance` never terminates on cancellation path

**File:** `Locus/Pipeline/VoicePipeline.swift` lines 165-167

```swift
while speakingTask != nil && !Task.isCancelled {
    try? await Task.sleep(for: .milliseconds(100))
}
```

`generationTask` is a `Task<Void, Never>` (non-throwing), but the code calls `try? await Task.sleep` which throws `CancellationError` when the task is cancelled. With `try?`, the error is swallowed, but `Task.isCancelled` becomes `true` so the loop does exit. However, there is a real problem: if `interrupt()` cancels `generationTask` while this loop is spinning, and `speakingTask` was already set to `nil` by a just-completed TTS call, the code falls through to set `state = .listening` **after** `interrupt()` already set `state = .listening`. This is benign. But the dangerous scenario is: `interrupt()` sets `speakingTask = nil`, then the cancelled generationTask's continuation runs `state = .listening` — this is fine.

The **actual** critical issue is different: if TTS `speak()` takes a very long time (or hangs), this loop polls at 100ms forever while holding the generationTask alive. There is no timeout.

**Fix:** Add a timeout to the polling loop (e.g., 60 seconds), and use `AsyncStream`/continuation instead of polling.

---

### 2. VoicePipeline: `processNextSentence` / `speakingTask` race with `interrupt()`

**File:** `Locus/Pipeline/VoicePipeline.swift` lines 181-189

```swift
private func processNextSentence() {
    guard speakingTask == nil, !sentenceQueue.isEmpty else { return }
    let sentence = sentenceQueue.removeFirst()
    state = .speaking
    speakingTask = Task {
        await ttsManager.speak(sentence)
        speakingTask = nil          // <-- HERE
        processNextSentence()       // <-- AND HERE
    }
}
```

When `interrupt()` runs, it sets `speakingTask = nil` and cancels the old task. But the cancelled `ttsManager.speak()` call will return (after cancellation), and then the task body continues to execute `speakingTask = nil` and `processNextSentence()`. This means:
- After `interrupt()` clears the queue, the old speaking task's continuation calls `processNextSentence()` with an empty queue (benign, but wasteful).
- Worse: if the timing is such that `interrupt()` runs between `speakingTask = nil` and `processNextSentence()`, a new sentence could be enqueued by a racing `handleSentence` callback from the buffer flush, leading to zombie TTS playback after interruption.

**Fix:** Check `Task.isCancelled` before setting `speakingTask = nil` and before calling `processNextSentence()`:

```swift
speakingTask = Task {
    await ttsManager.speak(sentence)
    guard !Task.isCancelled else { return }
    speakingTask = nil
    processNextSentence()
}
```

---

### 3. STTManager: Audio tap spawns unbounded Tasks — backpressure failure

**File:** `Locus/STT/STTManager.swift` lines 98-108

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
    Task {
        do {
            _ = try await manager.process(audioBuffer: buffer)
        } catch {
            ...
        }
    }
}
```

The audio tap callback fires on a real-time audio thread at ~93 times/second (4096 samples at 16kHz-equivalent). Each invocation spawns an unstructured `Task`. If `manager.process()` takes longer than the tap interval (e.g., under CPU pressure), tasks pile up unboundedly. The `AVAudioPCMBuffer` may also be reused/invalidated by the audio engine before the Task runs.

**Fix:**
- Use a serial `AsyncStream` or actor-isolated queue to feed audio buffers, applying backpressure.
- Copy the buffer data before leaving the tap callback, since `AVAudioPCMBuffer` is not guaranteed to remain valid.

---

### 4. VoicePipeline: `configure()` silently swallows LLM load failure with `try?`

**File:** `Locus/Pipeline/VoicePipeline.swift` line 56

```swift
try? await llmManager.loadModel(path: path)
```

If the LLM fails to load (corrupt file, out of memory), the pipeline sets `isReady = true` anyway. The user sees the main UI but every generation attempt silently produces no output (the guard in `generate()` calls `continuation.finish()` immediately). There is no error feedback.

**Fix:** Catch the error, set `loadingStatus` to an error message, and do not set `isReady = true`. Or set a dedicated error state that the UI can display.

---

### 5. LLMManager: `generate()` overwrites `generationTask` without cancelling the previous one

**File:** `Locus/LLM/LLMManager.swift` lines 31-95

```swift
func generate(prompt: String, ...) -> AsyncStream<String> {
    AsyncStream { continuation in
        generationTask = Task { ... }
    }
}
```

If `generate()` is called twice rapidly (e.g., two utterances in quick succession), the second call overwrites `generationTask` without cancelling the first. The first task continues running, producing tokens into a now-abandoned `AsyncStream` continuation, and competing for the same `LlamaContext` actor. Since `LlamaContext` is an actor, the calls serialize, but the interleaving of two generation sessions on the same context produces garbage output.

**Fix:** Cancel the previous `generationTask` at the start of `generate()`:

```swift
func generate(...) -> AsyncStream<String> {
    generationTask?.cancel()
    return AsyncStream { continuation in
        generationTask = Task { ... }
    }
}
```

---

### 6. Conversation history grows without bound — context window overflow

**File:** `Locus/Pipeline/VoicePipeline.swift` line 10, `Locus/LLM/LLMManager.swift` lines 44-52

`conversationHistory` is an ever-growing array. Every message is included in the ChatML prompt. The LLM context window is 2048 tokens. After roughly 10-15 exchanges, the prompt will exceed 2048 tokens, causing `completionInit` to throw `promptTooLong`. This error propagates through the `generate()` method's catch block, setting `llmManager.error` but the pipeline never checks it — it just sees zero tokens and appends an empty assistant message.

**Fix:**
- Implement a sliding window or token-counting strategy that trims old messages to stay within context.
- After trimming, always keep the system prompt and the latest user message.

---

### 7. LLMManager: Prompt includes current user message twice

**File:** `Locus/LLM/LLMManager.swift` lines 46-50

```swift
for message in history {
    let role = message.role == .user ? "user" : "assistant"
    fullPrompt += "<|im_start|>\(role)\n\(message.text)<|im_end|>\n"
}
fullPrompt += "<|im_start|>user\n\(prompt)<|im_end|>\n"
```

In `VoicePipeline.handleUtterance()`, the user message is appended to `conversationHistory` *before* calling `generate(prompt: text, history: conversationHistory)`. So `history` already contains the current user message at the end, and then `prompt` adds it again. The LLM sees the user's message twice.

**Fix:** Either:
- Don't append the user message to history before calling generate (append it after), or
- Don't pass `prompt` separately — just use the last message in `history`.

---

## HIGH (causes incorrect behavior or degraded experience)

### 8. SentenceBuffer: False splits on abbreviations, decimals, ellipses, and URLs

**File:** `Locus/Pipeline/SentenceBuffer.swift` lines 57-68

The boundary detection splits on any `.`, `!`, `?` followed by a space. This incorrectly splits:
- `"Dr. Smith"` -> `"Dr."` + `"Smith"`
- `"3.14 is pi"` -> `"3."` + `"14 is pi"`
- `"U.S. policy"` -> `"U."` + `"S."` + `"policy"`
- `"e.g. this"` -> `"e."` + `"g."` + `"this"`
- `"Go to google.com for info"` -> `"Go to google."` + `"com for info"`

Each fragment is sent to TTS individually, producing choppy unnatural speech.

**Fix:** Add heuristics: require the character after the space to be uppercase for period-splits, or maintain a list of common abbreviations, or require a minimum sentence length before splitting.

---

### 9. SentenceBuffer: Never splits on `:` or `;` — very long sentences

Colons and semicolons are common in LLM output (e.g., "Here's what you need to know: first, ..."). The buffer only splits on `.!?`, so a long clause-heavy sentence without terminal punctuation will buffer indefinitely until the LLM happens to produce a period. This causes long TTS latency for the first audible output.

**Fix:** Add `:` and `;` as secondary split points, or implement a maximum character limit that forces a split at the nearest word boundary.

---

### 10. TTSManager: `speak()` sets `speakTask` after `await task.value` — ordering issue

**File:** `Locus/TTS/TTSManager.swift` lines 64-131

```swift
let task = Task { ... }
speakTask = task           // set AFTER task starts
await task.value           // wait for completion
```

The `Task` starts executing immediately when created. If the task body completes very quickly (e.g., empty text after trimming, or engine error), `speakTask` is set *after* the task has already finished. Meanwhile, if `stop()` is called between task creation and `speakTask = task`, it cancels the *old* speakTask (already nil or from a previous call), not the currently running one.

**Fix:** Set `speakTask` before starting the task, or use a different synchronization pattern.

---

### 11. STTManager: `stopListening()` fires `finish()` in unstructured Task — callbacks after stop

**File:** `Locus/STT/STTManager.swift` lines 127-139

```swift
func stopListening() {
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil
    isListening = false
    Task {
        _ = try? await asrManager?.finish()
        await asrManager?.reset()
    }
    ...
}
```

The `finish()` call may trigger final EOU/partial callbacks *after* `isListening` is already `false`. These callbacks dispatch to MainActor and call `onUtteranceCompleted`, which calls `handleUtterance`. The pipeline's guard `guard state == .listening` should catch this, but there's a window where `interrupt()` set state to `.listening` and a stale EOU fires, causing an unwanted generation.

**Fix:** Set a `isStopping` flag, or nil out the callbacks before calling `finish()`, or `await` the finish task synchronously.

---

### 12. STTManager: `resetForNextUtterance()` races with in-flight audio processing Tasks

**File:** `Locus/STT/STTManager.swift` lines 143-149

```swift
func resetForNextUtterance() {
    hasFiredSpeechDetected = false
    partialResult = ""
    Task {
        await asrManager?.reset()
    }
}
```

The `reset()` is dispatched asynchronously. Meanwhile, audio tap Tasks from before the reset are still in-flight and calling `manager.process()`. These process calls and the reset call race on the `asrManager` actor. Audio processed after reset is fine, but audio processed *during* reset (if the manager's internal state is partially cleared) could cause undefined behavior depending on FluidAudio's implementation.

**Fix:** Stop the audio tap, await reset, then reinstall the tap. Or accept the race if FluidAudio's actor serialization handles it safely.

---

### 13. TTSManager + STTManager: AVAudioSession conflicts

**File:** `Locus/STT/STTManager.swift` line 89-91, `Locus/TTS/TTSManager.swift` lines 72-73

Both managers independently call `setCategory(.playAndRecord)` and `setActive(true)`. During barge-in, STT is listening while TTS starts speaking. TTS calls `setCategory` again (redundant but harmless), then creates a new `AVAudioEngine`. When TTS finishes, `stopAudioEngine()` stops its engine but does NOT call `setActive(false)` — which is correct. However, the STT audio engine's input node tap may be disrupted when TTS creates and destroys its own audio engine, because they share the same audio session.

On iOS, having two `AVAudioEngine` instances simultaneously (one for input, one for output) can cause the input engine to stop receiving audio silently.

**Fix:** Use a single shared `AVAudioEngine` for both STT input and TTS output, or carefully manage the audio session lifecycle to avoid conflicts.

---

### 14. VoicePipeline: No state recovery after errors

If `llmManager.generate()` throws internally (e.g., `promptTooLong`), the generationTask finishes without producing tokens. The `sentenceBuffer.flush()` emits nothing. The pipeline then polls `speakingTask` (which is nil), and sets `state = .listening`. This appears to recover, but `currentResponse` is empty and an empty assistant message is appended to `conversationHistory`, polluting future prompts.

**Fix:** Check if `currentResponse` is empty after generation and skip appending the assistant message. Or detect errors from the LLM and show feedback.

---

### 15. LlamaContext: `llama_backend_init()` called per model load, `llama_backend_free()` in deinit

**File:** `Locus/LLM/LlamaContext.swift` lines 44, 95

`llama_backend_init()` is called in `create()` and `llama_backend_free()` in `deinit`. If two LlamaContext instances are created (e.g., pipeline + LLMTestView each create one via separate LLMManagers), the second `deinit` calls `llama_backend_free()` while the first context is still alive, corrupting global state.

**Fix:** Use a static reference count for backend init/free, or init the backend once at app startup.

---

## MEDIUM (suboptimal behavior, potential issues under stress)

### 16. VoicePipeline: Barge-in can trigger double interrupt

**File:** `Locus/Pipeline/VoicePipeline.swift` lines 109-130

Both `onSpeechDetected` and `handleUtterance` check for `.processing`/`.speaking` state and call `interrupt()`. If speech is detected (triggering `onSpeechDetected` -> `interrupt()`), and then the EOU fires shortly after (triggering `handleUtterance` which also checks and calls `interrupt()`), `interrupt()` runs twice. The second call is mostly harmless (cancelling already-nil tasks, clearing already-empty queue) but it redundantly calls `ttsManager.stop()` and `llmManager.stopGeneration()`.

**Fix:** Add an early return in `interrupt()` if already in `.listening` state, or use a debounce flag.

---

### 17. SentenceBuffer: Not thread-safe

**File:** `Locus/Pipeline/SentenceBuffer.swift`

`SentenceBuffer` is a plain `class` (not `@MainActor`, not an `actor`). It is accessed from VoicePipeline (which is `@MainActor`), so all accesses happen on the main actor — this is currently safe. However, the `onSentenceReady` callback is set in `setupCallbacks()` and fires during `append()` which is called during `for await token in ...` inside a `Task` on the MainActor. This is safe because VoicePipeline is `@MainActor` and the Task inherits the actor context. But it's fragile — any refactoring could break this assumption.

**Fix:** Mark `SentenceBuffer` as `@MainActor` to make the safety constraint explicit.

---

### 18. ModelManager: No download resumption or cancellation

**File:** `Locus/Models/ModelManager.swift` lines 110-158

Downloads use `URLSession.shared.download(from:)` with no progress tracking (only file-level completion), no resume capability, and no cancellation support. A 1.26 GB download that fails at 99% must restart from scratch. The user cannot cancel a download in progress.

**Fix:**
- Use `URLSession` download tasks with delegate for byte-level progress.
- Save resume data on failure and use `downloadTask(withResumeData:)`.
- Store the `Task` handle and provide a cancel method.

---

### 19. ModelManager: `triggerLocalNetworkPermission` retries 15 times with 2-second delays

**File:** `Locus/Models/ModelManager.swift` lines 95-108

In production (`#else` branch pointing to `https://download.moonshine.ai`), this function still runs, making up to 15 probe requests with 2-second sleeps between failures — potentially blocking the download for 30 seconds on network issues. The local network permission trigger is only relevant for `#if DEBUG`.

**Fix:** Gate the entire `triggerLocalNetworkPermission()` call behind `#if DEBUG`.

---

### 20. ModelManager: Skip button sets `llmReady = true` without a model file

**File:** `Locus/Models/ModelDownloadView.swift` line 79

```swift
Button("Skip (use placeholder data)") {
    modelManager.llmReady = true
}
```

This sets `llmReady = true` so `allModelsReady` returns `true`, advancing to the loading screen. But `llmModelPath` returns `nil` (no file exists). `VoicePipeline.configure()` skips LLM loading (`if let path = llmModelPath`), sets `isReady = true`, and the user reaches the pipeline view with no LLM loaded. Every utterance produces empty responses. There is no error feedback.

**Fix:** Either remove the skip button from release builds, or show a warning that LLM is unavailable, or handle the nil-LLM case gracefully in the pipeline.

---

### 21. LLMManager: ASCII-only filter strips valid non-ASCII characters

**File:** `Locus/LLM/LLMManager.swift` line 73

```swift
let cleaned = String(token.unicodeScalars.filter { $0.isASCII })
```

This strips all non-ASCII characters including accented letters (e, n, u), emoji, and characters from non-Latin scripts. If the user asks a question in French, Spanish, etc., the response will have missing characters.

**Fix:** Instead of ASCII filtering, filter only known problematic control characters or the specific artifacts you're trying to remove.

---

### 22. SystemMetrics: Timer is never invalidated

**File:** `Locus/Debug/SystemMetrics.swift` lines 18-25

`startMonitoring()` is called once in `LocusApp` but `stopMonitoring()` is never called. The `Timer` fires every second for the entire app lifetime. The timer closure captures `[weak self]`, so it won't prevent deallocation, but `SystemMetrics` is held by `LocusApp` as a `@StateObject` so it lives forever anyway. The timer continues firing even when the metrics overlay is hidden.

**Fix:** Gate the timer on `isVisible`, or accept the minor overhead (1 call/second is negligible).

---

### 23. LlamaContext: No protection against concurrent `completionInit` + `completionLoop`

**File:** `Locus/LLM/LlamaContext.swift`

`LlamaContext` is an `actor`, so all methods are serialized. This is correct. However, if `clear()` is called while `completionLoop()` calls are queued on the actor, the loop will execute after the clear and operate on stale state (`isDone` is false after clear, but the context's KV cache has been cleared). The `llama_decode` call in `completionLoop` may produce garbage or crash.

**Fix:** Add a generation ID or epoch counter. Check it in `completionLoop()` to detect stale callers:

```swift
private var epoch: Int = 0

func clear() {
    epoch += 1
    ...
}

func completionLoop(forEpoch: Int) -> String? {
    guard forEpoch == epoch else { return nil }
    ...
}
```

---

### 24. TTS warmup stream not fully consumed

**File:** `Locus/TTS/TTSManager.swift` lines 43-46

```swift
let stream = try await manager.synthesizeStreaming(text: "Hi", voice: "alba")
for try await _ in stream {
    break // One frame is enough
}
```

Breaking out of the `for try await` loop cancels the stream's underlying task. Depending on FluidAudio's implementation, this may leave internal state in an inconsistent state, or leak resources. Some streaming APIs require full consumption or explicit cancellation.

**Fix:** Verify FluidAudio handles mid-stream cancellation cleanly. If not, consume the full stream for the short warmup text.

---

## LOW (minor issues, code quality)

### 25. VoicePipeline: `currentResponse` shows stale text

After generation completes and state transitions to `.listening`, `currentResponse` retains the last response text. The UI only shows it during `.processing` state (line 20 of PipelineView), so this is cosmetically fine, but the stale data persists in memory and in the published property.

**Fix:** Clear `currentResponse` when transitioning away from `.processing`/`.speaking`.

---

### 26. PipelineView: Partial response only shown during `.processing`, not `.speaking`

**File:** `Locus/Pipeline/PipelineView.swift` line 20

```swift
if !pipeline.currentResponse.isEmpty && pipeline.state == .processing {
```

Once state changes to `.speaking` (first sentence ready), the partial response bubble disappears. The user loses the streaming text feedback.

**Fix:** Show the partial response during both `.processing` and `.speaking` states.

---

### 27. Multiple `LLMManager` / `STTManager` / `TTSManager` instances

`LLMTestView` creates its own `@StateObject private var llmManager = LLMManager()`. `STTTestView` and `TTSTestView` do the same. These are separate instances from the pipeline's managers. The LLMTestView loads the model a second time, doubling memory usage. The STTTestView creates a second audio engine with a second tap.

**Fix:** Share manager instances via `@EnvironmentObject`, or accept the duplication for debug/test tabs.

---

### 28. ConversationMessage is not Equatable/Hashable

**File:** `Locus/Models/ConversationModel.swift`

`ConversationMessage` conforms to `Identifiable` but not `Equatable`. SwiftUI's `ForEach` diffing works via `id`, but `onChange(of: pipeline.conversationHistory.count)` relies on count changes. If messages were ever replaced (same count), the scroll would not update.

**Fix:** Conform `ConversationMessage` to `Equatable` for robustness.

---

### 29. No microphone permission handling

**File:** `Locus/STT/STTManager.swift`

`startListening()` accesses `AVAudioEngine().inputNode` without checking or requesting microphone permission. On first launch, iOS will show the permission dialog, but if denied, the audio engine will fail with an opaque error. There is no specific handling for the "permission denied" case.

**Fix:** Check `AVAudioApplication.shared.recordPermission` before starting, request permission if needed, and show a clear error if denied.

---

### 30. ModelManager: Parallel downloads but single error reporting

**File:** `Locus/Models/ModelManager.swift` lines 137-154

Inside `withTaskGroup`, each download task sets `self.error` on failure. If multiple files fail, only the last error is visible. Also, a successful download of one file can overwrite the progress of a failed download, making it appear complete.

**Fix:** Collect all errors and report them together, or fail fast on the first error.

---

## Summary by Priority

| Priority | Count | Key Theme |
|----------|-------|-----------|
| CRITICAL | 7 | Stuck states, race conditions, context overflow, duplicate prompt |
| HIGH | 8 | Sentence splitting, audio conflicts, stale callbacks, missing error handling |
| MEDIUM | 9 | Resource management, thread safety, download robustness |
| LOW | 6 | Code quality, UX polish |

### Top 5 fixes for immediate impact:

1. **Fix the duplicate user message in the prompt** (#7) -- causes every response to be based on seeing the user's message twice, degrading quality.
2. **Add context window management** (#6) -- the app will break after ~10 exchanges.
3. **Handle LLM load failure** (#4) -- currently results in a silently broken app.
4. **Add `Task.isCancelled` guard in `processNextSentence`** (#2) -- prevents zombie TTS after barge-in.
5. **Fix audio tap backpressure** (#3) -- under CPU load, unbounded task spawning can overwhelm the system.
