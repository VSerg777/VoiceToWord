import AppKit
import AVFoundation
import ApplicationServices
import AudioToolbox
import CoreAudio
import Foundation
import VoskAPI

private func resultText(_ cString: UnsafePointer<CChar>?) -> String {
    guard let cString,
          let bytes = String(cString: cString).data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return "" }
    return (object["text"] as? String) ?? (object["partial"] as? String) ?? ""
}

private func audioDevices() -> [(id: AudioDeviceID, name: String)] {
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var inputAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var inputSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &inputAddress, 0, nil, &inputSize) == noErr, inputSize > 0 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(inputSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &inputSize, memory) == noErr else { return nil }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        guard buffers.contains(where: { $0.mNumberChannels > 0 }) else { return nil }
        var nameAddress = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
              let value = name?.takeUnretainedValue() else { return nil }
        return (id, value as String)
    }
}

private final class DictationEngine {
    private(set) var text = ""
    private var undo: [String] = []
    private var lastPhrase = ""

    func clear() { text = ""; undo.removeAll(); lastPhrase = "" }

    func apply(_ speech: String) {
        let old = text
        let command = speech.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "ё", with: "е")
        if ["отмени", "отмени это", "отмена", "отмени последнее действие"].contains(command) {
            if let previous = undo.popLast() { text = previous }
            lastPhrase = ""
            return
        }
        if command == "удали последнее слово" || command == "удалить последнее слово" {
            text = text.replacingOccurrences(of: #"\s*[^\s]+\s*$"#, with: "", options: .regularExpression)
        } else if command == "удали это" || command == "удали последнюю фразу" {
            if !lastPhrase.isEmpty && text.hasSuffix(lastPhrase) { text.removeLast(lastPhrase.count) }
        } else if command.hasPrefix("замени "), speech.range(of: #"^замени (.+?) на (.+)$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            let match = try? NSRegularExpression(pattern: #"^замени (.+?) на (.+)$"#, options: .caseInsensitive)
            if let match, let m = match.firstMatch(in: speech, range: NSRange(speech.startIndex..., in: speech)),
               let a = Range(m.range(at: 1), in: speech), let b = Range(m.range(at: 2), in: speech) {
                let find = String(speech[a]), replacement = String(speech[b])
                if let expression = try? NSRegularExpression(pattern: "(?<!\\p{L})" + NSRegularExpression.escapedPattern(for: find) + "(?!\\p{L})", options: .caseInsensitive) {
                    let hits = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
                    if hits.count == 1, let r = Range(hits[0].range, in: text) { text.replaceSubrange(r, with: replacement) }
                }
            }
        } else {
            let literal = command.hasPrefix("буквально ")
            var content = literal ? String(speech.trimmingCharacters(in: .whitespacesAndNewlines).dropFirst("буквально ".count)) : speech.trimmingCharacters(in: .whitespacesAndNewlines)
            if !literal {
                let commands: [(String, String)] = [("точка с запятой", ";"), ("вопросительный знак", "?"), ("восклицательный знак", "!"), ("новый абзац", "\n\n"), ("новая строка", "\n"), ("двоеточие", ":"), ("запятая", ","), ("точка", ".")]
                for (word, symbol) in commands {
                    content = content.replacingOccurrences(of: #"(?<!\p{L})"# + NSRegularExpression.escapedPattern(for: word) + #"(?!\p{L})"#, with: symbol, options: [.regularExpression, .caseInsensitive])
                }
            }
            if !text.isEmpty, let last = text.last, !last.isWhitespace, let first = content.first, !",.;:!?\n".contains(first) { text += " " }
            text += content
            if !literal {
                text = text.replacingOccurrences(of: #" +([,.;:!?])"#, with: "$1", options: .regularExpression)
                text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
                text = text.replacingOccurrences(of: #"([,.;:!?])(?=\p{L})"#, with: "$1 ", options: .regularExpression)
                text = text.replacingOccurrences(of: #"(^|[.!?]\s+|\n)(\p{L})"#, with: "$1$2".uppercased(), options: .regularExpression)
                if old.isEmpty { text = text.prefix(1).uppercased() + text.dropFirst() }
            }
            lastPhrase = text.hasPrefix(old) ? String(text.dropFirst(old.count)) : ""
        }
        if old != text { undo.append(old) }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var modelField: NSTextField!
    private var devicePopup: NSPopUpButton!
    private var targetPopup: NSPopUpButton!
    private var status: NSTextField!
    private var transcriptView: NSTextView!
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var model: OpaquePointer?
    private var audioEngine: AVAudioEngine?
    private var recognizer: OpaquePointer?
    private let dictation = DictationEngine()
    private var devices: [(id: AudioDeviceID, name: String)] = []
    private var targetProcessIDs: [pid_t] = []
    private var partial = ""
    private var isListening = false
    private var monitor: Any?
    private var localMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildWindow()
        refreshDevices()
        refreshTargets()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.control, .option]), event.charactersIgnoringModifiers?.lowercased() == "d" else { return }
            Task { @MainActor in self?.toggleDictation() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.modifierFlags.contains([.control, .option]), event.charactersIgnoringModifiers?.lowercased() == "d" else { return event }
            Task { @MainActor in self?.toggleDictation() }
            return nil
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopDictation()
        if let model { vosk_model_free(model) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
    }

    private func buildWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 550), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Vosk Word Listener for Mac"
        window.center()
        let root = NSStackView(); root.orientation = .vertical; root.alignment = .leading; root.spacing = 12; root.translatesAutoresizingMaskIntoConstraints = false
        let modelRow = NSStackView(); modelRow.orientation = .horizontal; modelRow.spacing = 8
        modelField = NSTextField(string: ""); modelField.placeholderString = "Папка русской модели Vosk (с am/final.mdl)"
        let browse = NSButton(title: "Выбрать модель…", target: self, action: #selector(chooseModel)); browse.bezelStyle = .rounded
        let load = NSButton(title: "Загрузить", target: self, action: #selector(loadModel)); load.bezelStyle = .rounded
        modelRow.addArrangedSubview(modelField); modelRow.addArrangedSubview(browse); modelRow.addArrangedSubview(load)
        devicePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        let refresh = NSButton(title: "Обновить микрофоны", target: self, action: #selector(refreshDevices)); refresh.bezelStyle = .rounded
        let deviceRow = NSStackView(views: [devicePopup, refresh]); deviceRow.orientation = .horizontal; deviceRow.spacing = 8
        targetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        targetPopup.target = self; targetPopup.action = #selector(targetChanged)
        let refreshTargetsButton = NSButton(title: "Обновить приложения", target: self, action: #selector(refreshTargets)); refreshTargetsButton.bezelStyle = .rounded
        let targetLabel = NSTextField(labelWithString: "Куда вставлять текст:")
        let targetRow = NSStackView(views: [targetLabel, targetPopup, refreshTargetsButton]); targetRow.orientation = .horizontal; targetRow.spacing = 8
        let buttonRow = NSStackView(); buttonRow.orientation = .horizontal; buttonRow.spacing = 8
        startButton = NSButton(title: "Диктовать  (⌃⌥D)", target: self, action: #selector(startDictation)); startButton.bezelStyle = .rounded
        stopButton = NSButton(title: "Остановить", target: self, action: #selector(stopDictation)); stopButton.bezelStyle = .rounded; stopButton.isEnabled = false
        let copy = NSButton(title: "Копировать текст", target: self, action: #selector(copyText)); copy.bezelStyle = .rounded
        buttonRow.addArrangedSubview(startButton); buttonRow.addArrangedSubview(stopButton); buttonRow.addArrangedSubview(copy)
        status = NSTextField(labelWithString: "Выберите папку русской модели Vosk и нажмите «Загрузить»."); status.lineBreakMode = .byWordWrapping
        transcriptView = NSTextView(); transcriptView.isEditable = false; transcriptView.font = .systemFont(ofSize: 15); transcriptView.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = transcriptView; scroll.translatesAutoresizingMaskIntoConstraints = false
        for view in [modelRow, deviceRow, targetRow, buttonRow] { view.translatesAutoresizingMaskIntoConstraints = false; root.addArrangedSubview(view) }
        root.addArrangedSubview(status); root.addArrangedSubview(scroll)
        window.contentView?.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 18), root.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -18), root.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 18), root.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -18),
            modelRow.widthAnchor.constraint(equalTo: root.widthAnchor), deviceRow.widthAnchor.constraint(equalTo: root.widthAnchor), targetRow.widthAnchor.constraint(equalTo: root.widthAnchor), buttonRow.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.widthAnchor.constraint(equalTo: root.widthAnchor), scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 250), modelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280), targetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 280)
        ])
        if let saved = UserDefaults.standard.string(forKey: "modelPath") { modelField.stringValue = saved }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func chooseModel() {
        let picker = NSOpenPanel(); picker.canChooseFiles = false; picker.canChooseDirectories = true; picker.allowsMultipleSelection = false; picker.message = "Выберите распакованную папку русской модели Vosk"
        if picker.runModal() == .OK, let url = picker.url { modelField.stringValue = url.path }
    }

    nonisolated private static func loadVoskModel(_ path: String) -> OpaquePointer? {
        vosk_set_log_level(-1)
        return path.withCString { vosk_model_new($0) }
    }

    @objc private func loadModel() {
        let path = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard FileManager.default.fileExists(atPath: path + "/am/final.mdl") else { status.stringValue = "Папка не содержит am/final.mdl. Скачайте и распакуйте русскую модель Vosk."; return }
        if let model { vosk_model_free(model); self.model = nil }
        status.stringValue = "Загружаю модель в память…"
        let loaded = Self.loadVoskModel(path)
        if let loaded { model = loaded; UserDefaults.standard.set(path, forKey: "modelPath"); status.stringValue = "Модель загружена. Выберите микрофон и нажмите «Диктовать»." }
        else { status.stringValue = "Не удалось загрузить Vosk модель. Проверьте папку и свободную память." }
    }

    @objc private func refreshDevices() {
        devices = [(id: AudioDeviceID(0), name: "Системный микрофон Mac (по умолчанию)")] + audioDevices()
        devicePopup.removeAllItems()
        for device in devices { devicePopup.addItem(withTitle: device.name) }
        devicePopup.selectItem(at: 0)
        if devices.count == 1 { status.stringValue = "Используется системный микрофон Mac. Проверьте его в System Settings → Sound → Input." }
    }

    @objc private func refreshTargets() {
        targetPopup.removeAllItems()
        targetProcessIDs = [0]
        targetPopup.addItem(withTitle: "Активное поле (переключитесь после старта)")
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular && $0.localizedName != nil }
            .sorted { ($0.localizedName ?? "").localizedCaseInsensitiveCompare($1.localizedName ?? "") == .orderedAscending }
        for app in apps {
            targetPopup.addItem(withTitle: app.localizedName ?? "Приложение")
            targetProcessIDs.append(app.processIdentifier)
        }
        let savedPID = UserDefaults.standard.integer(forKey: "targetProcessID")
        let restore = targetProcessIDs.firstIndex(of: pid_t(savedPID)) ?? 0
        targetPopup.selectItem(at: restore)
        updateTargetStatus()
    }

    @objc private func targetChanged() {
        guard targetPopup.indexOfSelectedItem >= 0, targetPopup.indexOfSelectedItem < targetProcessIDs.count else { return }
        UserDefaults.standard.set(Int(targetProcessIDs[targetPopup.indexOfSelectedItem]), forKey: "targetProcessID")
        updateTargetStatus()
    }

    private func updateTargetStatus() {
        guard targetPopup != nil, !isListening else { return }
        if targetPopup.indexOfSelectedItem == 0 {
            status.stringValue = "Куда вставлять: активное поле. После старта переключитесь в нужное приложение и поставьте курсор."
        } else {
            status.stringValue = "Куда вставлять: \(targetPopup.titleOfSelectedItem ?? "выбранное приложение"). Поставьте курсор в нужное поле этого приложения."
        }
    }

    @objc private func startDictation() { beginDictation() }
    private func beginDictation() {
        guard !isListening, model != nil else { if model == nil { status.stringValue = "Сначала загрузите русскую модель Vosk." }; return }
        guard devicePopup.indexOfSelectedItem >= 0, devicePopup.indexOfSelectedItem < devices.count else { status.stringValue = "Выберите доступный микрофон."; return }
        if !AXIsProcessTrusted() { status.stringValue = "Чтобы печатать в другие приложения, включите Vosk Word Listener в System Settings → Privacy & Security → Accessibility. Разрешите микрофон при запросе." }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                guard granted else { self.status.stringValue = "Нет доступа к микрофону. Разрешите его в System Settings → Privacy & Security → Microphone."; return }
                self.startAudio()
            }
        }
    }

    private func startAudio() {
        guard let model else { return }
        guard let recognizer = vosk_recognizer_new(model, 16_000) else { status.stringValue = "Vosk не смог создать распознаватель."; return }
        self.recognizer = recognizer
        let engine = AVAudioEngine(); self.audioEngine = engine
        do {
            let input = engine.inputNode
            let device = devices[devicePopup.indexOfSelectedItem].id
            if device != 0, let audioUnit = input.audioUnit {
                var selected = device
                // If this input disappears or macOS refuses to switch to it,
                // continue with the system-default microphone instead.
                _ = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &selected, UInt32(MemoryLayout<AudioDeviceID>.size))
            }
            let format = input.outputFormat(forBus: 0)
            guard let converter = AVAudioConverter(from: format, to: AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!) else { throw NSError(domain: "VoskMac", code: 2, userInfo: [NSLocalizedDescriptionKey: "Не удалось подготовить микрофон для распознавания."]) }
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
                guard let self else { return }
                let ratio = 16_000 / format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
                guard let converted = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return }
                var supplied = false
                converter.convert(to: converted, error: nil) { _, outStatus in
                    if supplied { outStatus.pointee = .noDataNow; return nil }
                    supplied = true; outStatus.pointee = .haveData; return buffer
                }
                guard let channel = converted.int16ChannelData else { return }
                let samples = UnsafeRawBufferPointer(start: channel[0], count: Int(converted.frameLength) * MemoryLayout<Int16>.size)
                let sampleCopy = Array(samples)
                let accepted = sampleCopy.withUnsafeBytes { raw -> Int32 in
                    guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return 0 }
                    return vosk_recognizer_accept_waveform(recognizer, base, Int32(raw.count))
                }
                let recognized = accepted != 0 ? resultText(vosk_recognizer_result(recognizer)) : resultText(vosk_recognizer_partial_result(recognizer))
                self.handleRecognition(recognized, isFinal: accepted != 0)
            }
            try engine.start()
            isListening = true; dictation.clear(); partial = ""; transcriptView.string = ""
            startButton.isEnabled = false; stopButton.isEnabled = true
            let destination = targetPopup.indexOfSelectedItem == 0 ? "активное приложение" : (targetPopup.titleOfSelectedItem ?? "выбранное приложение")
            status.stringValue = "Слушаю. Вставляю в: \(destination). Говорите по-русски. ⌃⌥D — остановить."
            if targetPopup.indexOfSelectedItem > 0,
               targetProcessIDs.indices.contains(targetPopup.indexOfSelectedItem),
               let targetApp = NSRunningApplication(processIdentifier: targetProcessIDs[targetPopup.indexOfSelectedItem]) {
                targetApp.activate(options: [.activateAllWindows])
            }
        } catch {
            engine.inputNode.removeTap(onBus: 0); self.audioEngine = nil; vosk_recognizer_free(recognizer); self.recognizer = nil; status.stringValue = "Ошибка аудио: \(error.localizedDescription)"
        }
    }

    private func handleRecognition(_ phrase: String, isFinal: Bool) {
        DispatchQueue.main.async {
            if isFinal {
                if !phrase.isEmpty {
                    let previous = self.dictation.text
                    self.dictation.apply(phrase)
                    self.applyEdit(from: previous, to: self.dictation.text)
                }
                self.partial = ""
            }
            else { self.partial = phrase }
            self.transcriptView.string = self.dictation.text + (self.partial.isEmpty ? "" : (self.dictation.text.isEmpty ? "" : " ") + self.partial)
            self.transcriptView.scrollToEndOfDocument(nil)
        }
    }

    private func applyEdit(from oldText: String, to newText: String) {
        guard oldText != newText else { return }
        guard AXIsProcessTrusted() else {
            status.stringValue = "Для ввода в другие приложения включите Accessibility в System Settings → Privacy & Security."
            return
        }
        var common = 0
        let old = Array(oldText.utf16), new = Array(newText.utf16)
        while common < old.count && common < new.count && old[common] == new[common] { common += 1 }
        let removed = String(decoding: old.dropFirst(common), as: UTF16.self)
        var added = String(decoding: new.dropFirst(common), as: UTF16.self)
        let targetPID = targetProcessIDs.indices.contains(targetPopup.indexOfSelectedItem) ? targetProcessIDs[targetPopup.indexOfSelectedItem] : 0
        let cursorPosition = targetPID == 0 ? AXUIElementCreateSystemWide() : AXUIElementCreateApplication(targetPID)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(cursorPosition, kAXFocusedUIElementAttribute as CFString, &focusedValue) == .success,
              let focused = focusedValue as! AXUIElement? else {
            status.stringValue = targetPID == 0 ? "Не найдено активное поле ввода. Переключитесь в нужное приложение и поставьте курсор." : "В выбранном приложении нет активного поля ввода. Откройте его и поставьте курсор в текстовое поле."
            return
        }
        var selectedValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &selectedValue) == .success,
           let value = selectedValue, CFGetTypeID(value) == AXValueGetTypeID() {
            let range = unsafeBitCast(value, to: AXValue.self)
            var selected = CFRange(location: 0, length: 0)
            if AXValueGetValue(range, .cfRange, &selected) {
                if selected.length != 0 { status.stringValue = "Снимите выделение в целевом приложении перед диктовкой."; return }
                var value: CFTypeRef?
                if AXUIElementCopyAttributeValue(focused, kAXValueAttribute as CFString, &value) == .success, let existing = value as? String, selected.location <= existing.utf16.count, selected.length == 0, selected.location >= removed.utf16.count {
                    let replaced = String(decoding: existing.utf16.dropFirst(selected.location - removed.utf16.count).prefix(removed.utf16.count), as: UTF16.self)
                    guard replaced == removed else { status.stringValue = "Курсор или текст в целевом приложении изменился. Голосовая правка пропущена."; return }
                    let prior = String(decoding: existing.utf16.prefix(selected.location - removed.utf16.count), as: UTF16.self).last
                    let needsSpace = removed.isEmpty && (prior.map { !$0.isWhitespace } ?? false)
                    let punctuation = added.first.map { ",.;:!?\n".contains($0) } ?? false
                    if needsSpace && !punctuation { added = " " + added }
                    var targetRange = CFRange(location: selected.location - removed.utf16.count, length: removed.utf16.count)
                    if let targetAXRange = AXValueCreate(.cfRange, &targetRange) {
                        _ = AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, targetAXRange)
                    }
                    let setValueResult = AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString, added as CFString)
                    if setValueResult == .success { return }
                    if removed.isEmpty { typeText(added); return }
                    status.stringValue = "Целевое приложение не разрешило применить голосовую правку."
                    return
                }
            }
        }
        if removed.isEmpty { typeText(added) }
        else { status.stringValue = "Не удалось безопасно применить голосовую правку в этом поле." }
    }

    private func typeText(_ text: String) {
        guard AXIsProcessTrusted(), let source = CGEventSource(stateID: .hidSystemState), let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true), let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else { return }
        down.keyboardSetUnicodeString(stringLength: text.utf16.count, unicodeString: Array(text.utf16)); down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    @objc private func stopDictation() {
        guard isListening else { return }
        isListening = false; audioEngine?.inputNode.removeTap(onBus: 0); audioEngine?.stop(); audioEngine = nil
        if let recognizer {
            let final = resultText(vosk_recognizer_final_result(recognizer))
            if !final.isEmpty {
                let previous = dictation.text
                dictation.apply(final)
                applyEdit(from: previous, to: dictation.text)
            }
            vosk_recognizer_free(recognizer); self.recognizer = nil
        }
        partial = ""; transcriptView.string = dictation.text; startButton.isEnabled = model != nil; stopButton.isEnabled = false
        status.stringValue = "Остановлено. Модель остаётся в памяти."
    }

    @objc private func toggleDictation() { if isListening { stopDictation() } else { beginDictation() } }
    @objc private func copyText() { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(dictation.text, forType: .string) }
}

@main
private struct VoskMacApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
