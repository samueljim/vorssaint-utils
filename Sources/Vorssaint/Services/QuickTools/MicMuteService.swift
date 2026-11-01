// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import AudioToolbox
import CoreAudio
import Foundation

/// Applies each available microphone's mute control and drops its input
/// volume to zero. The mute switch on its own does not zero capture on many
/// Macs, so the volume has to go with it — the same control System Settings
/// uses. Apps can select their own input, so this covers devices beyond the
/// system default. These controls are not a privacy lock: Siri and some
/// voice-processing paths may ignore them, even when the properties read muted.
/// No captured audio is inspected, and the published state reports this
/// feature's state, not proof that every app receives silence.
/// Device, default-input and per-device level changes reapply the request, and
/// the state survives relaunches. A device this app changed stays its to
/// restore even while unplugged: it gets its saved level back when it returns.
final class MicMuteService: ObservableObject {
    static let shared = MicMuteService()

    @Published private(set) var isMuted = false
    @Published private(set) var shortcutRegistrationFailed = false

    private let hotkey = QuickToolHotkey(id: 12)
    private var installedListeners: [AudioObjectPropertySelector] = []
    /// Per-device mute and volume listeners, so an app that raises gain when
    /// a call starts cannot undo the mute. Device IDs go stale when hardware
    /// leaves, and the next sweep replaces this list from scratch.
    private var deviceListeners: [DeviceListener] = []
    /// Reading or writing a device property can block for as long as the audio
    /// daemon holds the device (a headset connecting, an interface waking),
    /// and that is exactly the moment the listeners fire. Sweeping every
    /// device on the main thread would hand the app one hang per reconnection,
    /// so all of it happens here, one sweep at a time.
    private let halQueue = DispatchQueue(label: "com.vorssaint.utils.micmute.hal", qos: .userInitiated)
    /// A sweep that finished after a newer one started must not publish what
    /// it saw.
    private var applyGeneration = 0
    /// What the last request asked for, kept from the moment it is queued.
    /// `isMuted` and the persisted flag only follow once the sweep has
    /// published, so a device change or a preference sync that lands while a
    /// sweep is still running must re-assert the request in flight, never the
    /// state it is replacing: read from the flag, a mute still being applied
    /// looked like "unmuted, with claims to release" and was silently undone.
    private var wantsMute = UserDefaults.standard.bool(forKey: DefaultsKey.micMuteActive)
    private let inputVolumeLock = NSLock()
    private var inputVolumeBlocked = false
    private var inputVolumeLifetime = UUID()

    private init() {
        hotkey.onPress = { [weak self] in self?.toggle() }
    }

    /// The smallest possible answer to a change: the system decides which
    /// thread this arrives on, so it only asks the main thread to re-assert
    /// the mute and returns. Handing a closure back to be removed never
    /// matches the one that was registered, so the plain callback is what
    /// makes stopping work.
    private static let listenerCallback: AudioObjectPropertyListenerProc = { _, _, _, client in
        guard let client else { return noErr }
        let service = Unmanaged<MicMuteService>.fromOpaque(client).takeUnretainedValue()
        DispatchQueue.main.async { service.reapplyIfNeeded() }
        return noErr
    }

    /// Unretained is safe here and only here: this is a single instance that
    /// lives as long as the app.
    private var listenerClient: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    func syncWithPreferences() {
        let available = AppFeature.micMute.isAvailable
        let enabled = available
            && UserDefaults.standard.bool(forKey: DefaultsKey.micMuteShortcutEnabled)
        let shortcut = GlobalShortcut.saved(for: DefaultsKey.micMuteShortcut,
                                            fallback: .micMuteDefault)
        shortcutRegistrationFailed = !hotkey.sync(enabled: enabled, shortcut: shortcut,
                                                  storageKey: DefaultsKey.micMuteShortcut)

        if available {
            if wantsMute {
                apply(muted: true, announce: false)
            } else if hasOutstandingClaims {
                // A device this app silenced and never got to release: it
                // was away at the unmute, or the app went down. Its level
                // comes back now if it is here, else when it returns.
                apply(muted: false, announce: false)
            }
            isMuted = wantsMute
        } else {
            // Switching the feature off must not strand a muted microphone
            // with no control left to unmute it.
            if wantsMute || hasOutstandingClaims {
                apply(muted: false, announce: false)
                UserDefaults.standard.set(false, forKey: DefaultsKey.micMuteActive)
            }
            isMuted = false
        }
        syncListeners()
    }

    /// The listeners exist to keep an active mute true while devices come and
    /// go, and to catch a claimed device coming back so it can be released;
    /// they live only as long as one of those is pending.
    private func syncListeners() {
        if isMuted || (AppFeature.micMute.isAvailable && hasOutstandingClaims) {
            installListeners()
        } else {
            removeListeners()
        }
        let watchDevices = isMuted
        halQueue.async { [weak self] in
            self?.syncDeviceListeners(muted: watchDevices)
        }
    }

    /// Devices this app silenced and has not yet put back, present or not.
    private var hasOutstandingClaims: Bool {
        !(UserDefaults.standard.stringArray(forKey: DefaultsKey.micMuteMutedDevices) ?? []).isEmpty
    }

    func suspend() {
        hotkey.unregister()
    }

    func toggle() {
        setMuted(!isMuted)
    }

    func setMuted(_ muted: Bool) {
        apply(muted: muted, announce: true)
    }

    var inputVolumeAdjustmentLifetime: UUID? {
        guard !UserDefaults.standard.bool(forKey: DefaultsKey.micMuteActive) else { return nil }
        return inputVolumeLock.withLock { inputVolumeBlocked ? nil : inputVolumeLifetime }
    }

    /// Called from the input manager's audio queue, never the main thread.
    /// Sharing the mute queue prevents an older gain write from reopening a
    /// microphone after the mute sweep has already silenced it.
    func withUnmutedInput(lifetime: UUID, _ adjustment: () -> Void) {
        halQueue.sync {
            guard inputVolumeAdjustmentLifetime == lifetime else { return }
            adjustment()
        }
    }

    /// Unmute for a caller that is about to tear the app down. The queue that
    /// carries a normal sweep may never be drained once the app is going away,
    /// and a microphone left cut by an app that no longer exists is the one
    /// failure this feature cannot afford, so this one waits.
    func unmuteForTeardown() {
        let defaults = UserDefaults.standard
        // A mute still being applied has not reached the flag yet, and a claim
        // is a device this app owes its level back whatever the flag says.
        guard wantsMute || defaults.bool(forKey: DefaultsKey.micMuteActive) || hasOutstandingClaims else { return }
        // Any sweep still in flight loses its right to publish, and this one
        // runs behind it on the same serial queue.
        applyGeneration += 1
        wantsMute = false
        _ = halQueue.sync {
            let outcome = Self.sweep(muted: false)
            self.removeDeviceListeners()
            return outcome
        }
        defaults.set(false, forKey: DefaultsKey.micMuteActive)
        isMuted = false
        inputVolumeLock.withLock {
            inputVolumeBlocked = false
            inputVolumeLifetime = UUID()
        }
        removeListeners()
    }

    /// Silently re-asserts the wanted state; used when the set of input
    /// devices, or the default one, changes underneath us. Unmuted, the same
    /// change is the moment a device this app still has to release may have
    /// come back.
    private func reapplyIfNeeded() {
        if wantsMute {
            apply(muted: true, announce: false)
        } else if hasOutstandingClaims {
            apply(muted: false, announce: false)
        }
    }

    // MARK: - Applying

    /// Hands the sweep to the audio queue and keeps the published state, the
    /// wanted state and the HUD on the main thread, where they belong.
    private func apply(muted: Bool, announce: Bool) {
        wantsMute = muted
        inputVolumeLock.withLock {
            inputVolumeBlocked = muted
            inputVolumeLifetime = UUID()
        }
        applyGeneration += 1
        let generation = applyGeneration
        halQueue.async { [weak self] in
            let outcome = Self.sweep(muted: muted)
            if muted {
                if outcome.applied { self?.syncDeviceListeners(muted: true) }
            } else if outcome.applied {
                self?.syncDeviceListeners(muted: false)
            }
            DispatchQueue.main.async {
                self?.finish(outcome, muted: muted, announce: announce, generation: generation)
            }
        }
    }

    /// Runs on `halQueue`. The record of what this app silenced is read here
    /// and written back here, so every sweep starts from what the one before
    /// it recorded. Two sweeps back to back are the normal case, not the
    /// exception: one headset connecting fires both listeners, and a quick
    /// double press queues two. Read on the main thread when each was asked
    /// for, both would start from the same record; the second would then find
    /// the devices the first had just silenced already quiet and unclaimed,
    /// leave them to "the user", and the unmute would never release them.
    private static func sweep(muted: Bool) -> MuteOutcome {
        let defaults = UserDefaults.standard
        let outcome = applyToDevices(
            muted: muted,
            savedVolumes: defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) as? [String: Double] ?? [:],
            savedChannelVolumes: defaults.dictionary(forKey: DefaultsKey.micMuteSavedChannelVolumes)
                as? [String: [String: Double]] ?? [:],
            // Missing means never tracked; an empty list means tracked and
            // owning nothing, and the sweep must keep those two apart.
            mutedDevices: defaults.stringArray(forKey: DefaultsKey.micMuteMutedDevices),
            legacyVolume: defaults.double(forKey: DefaultsKey.micMuteSavedVolume))
        // A sweep that reached nothing leaves the record alone: it is what a
        // later unmute needs to put every level back.
        if outcome.applied {
            defaults.set(outcome.savedVolumes, forKey: DefaultsKey.micMuteSavedVolumes)
            defaults.set(outcome.savedChannelVolumes, forKey: DefaultsKey.micMuteSavedChannelVolumes)
            defaults.set(outcome.mutedDevices, forKey: DefaultsKey.micMuteMutedDevices)
        }
        return outcome
    }

    /// Main thread. Publishes one sweep.
    private func finish(_ outcome: MuteOutcome, muted: Bool, announce: Bool, generation: Int) {
        guard generation == applyGeneration else { return }
        if outcome.applied {
            if isMuted != muted { isMuted = muted }
            UserDefaults.standard.set(muted, forKey: DefaultsKey.micMuteActive)
            syncListeners()
        } else {
            // Nothing was reached, so the request is dropped as it always was:
            // the published state stays what it is, and so does the wanted one.
            wantsMute = isMuted
            inputVolumeLock.withLock { inputVolumeBlocked = isMuted }
        }
        guard announce else { return }
        // Report a known failure even when no device could be changed. The
        // whole sentence matters, and it is longer than the island's wings.
        if outcome.failed {
            NotchService.shared.retractMicrophoneNotice()
            QuickToolHUD.show(icon: "exclamationmark.triangle",
                              message: muted ? L10n.shared.s.micMutePartialHUD : L10n.shared.s.micUnmutePartialHUD)
            return
        }
        guard outcome.applied else { return }
        // With Dynamic Island on, the switch reports there like the volume,
        // and the companion hushes or perks up, in its notice or where it is.
        let shownInIsland = NotchService.shared.showMicrophone(muted: muted)
        NotchService.shared.reactMascot(muted ? .hush : .perk)
        guard !shownInIsland else { return }
        QuickToolHUD.show(icon: muted ? "mic.slash.fill" : "mic.fill",
                          message: muted ? L10n.shared.s.micMutedHUD : L10n.shared.s.micUnmutedHUD)
    }

    // MARK: - CoreAudio

    private struct InputDevice {
        let id: AudioDeviceID
        let uid: String
    }

    private struct MuteOutcome {
        var applied: Bool
        var savedVolumes: [String: Double]
        /// Channel levels by device and element, so an unmute puts back the
        /// balance between channels instead of one level everywhere.
        var savedChannelVolumes: [String: [String: Double]]
        var mutedDevices: [String]
        /// A device this sweep had to reach and could not, next to ones it did.
        var failed = false
    }

    private struct DeviceListener {
        let device: AudioDeviceID
        var address: AudioObjectPropertyAddress
    }

    /// Runs on `halQueue`. Every CoreAudio call of a sweep happens here.
    private static func applyToDevices(muted: Bool,
                                       savedVolumes: [String: Double],
                                       savedChannelVolumes: [String: [String: Double]],
                                       mutedDevices: [String]?,
                                       legacyVolume: Double) -> MuteOutcome {
        let devices = inputDevices()
        guard !devices.isEmpty else {
            // Nothing to silence. An unmute has still done its job, and keeps
            // its claims for the devices that are away.
            return MuteOutcome(applied: !muted, savedVolumes: savedVolumes,
                               savedChannelVolumes: savedChannelVolumes, mutedDevices: mutedDevices ?? [])
        }
        return muted
            ? mute(devices, savedVolumes: savedVolumes, savedChannelVolumes: savedChannelVolumes,
                   mutedDevices: mutedDevices)
            : unmute(devices, savedVolumes: savedVolumes, savedChannelVolumes: savedChannelVolumes,
                     mutedDevices: mutedDevices, legacyVolume: legacyVolume)
    }

    private static func mute(_ devices: [InputDevice],
                             savedVolumes: [String: Double],
                             savedChannelVolumes: [String: [String: Double]],
                             mutedDevices: [String]?) -> MuteOutcome {
        var outcome = MuteOutcome(applied: false,
                                  savedVolumes: savedVolumes,
                                  savedChannelVolumes: savedChannelVolumes,
                                  mutedDevices: MicMuteSupport.absentClaims(recorded: mutedDevices,
                                                                            present: devices.map(\.uid)))
        let owned = Set(mutedDevices ?? [])
        for device in devices {
            let silenced = isSilenced(device.id)
            // Already quiet and not ours: a microphone the user muted
            // themselves is left alone, so unmuting later never opens
            // something this app did not close.
            if MicMuteSupport.shouldLeaveUntouched(owned: owned.contains(device.uid),
                                                   captureSilenced: silenced) {
                outcome.applied = true
                continue
            }
            if silenced {
                outcome.applied = true
                outcome.mutedDevices.append(device.uid)
                continue
            }
            let volume = inputVolume(of: device.id)
            if MicMuteSupport.shouldReplaceSavedVolume(existing: outcome.savedVolumes[device.uid],
                                                       current: volume),
               let volume {
                outcome.savedVolumes[device.uid] = Double(volume)
            }
            let channels = channelVolumes(of: device.id)
            if outcome.savedChannelVolumes[device.uid] == nil, !channels.isEmpty {
                outcome.savedChannelVolumes[device.uid] = channels
            }
            // Both controls, every time. A mute switch that reads back
            // engaged is not enough: capture on many Macs still hears the
            // volume, so the level has to go to zero as well.
            _ = setMuteSwitch(true, of: device.id)
            _ = setInputVolume(0, of: device.id)
            // Claimed only when the device really went quiet: a driver that
            // takes the write and keeps its level must not be recorded as
            // muted, or the unmute would raise a microphone it never lowered.
            if isSilenced(device.id) {
                outcome.applied = true
                outcome.mutedDevices.append(device.uid)
            } else {
                outcome.savedVolumes.removeValue(forKey: device.uid)
                outcome.savedChannelVolumes.removeValue(forKey: device.uid)
                // Only a microphone some app records from is left open. An aggregate
                // has no switch or level of its own; the microphones under it are
                // swept and reported on their own.
                var transport: UInt32 = 0
                var running: UInt32 = 0
                read(device.id, kAudioDevicePropertyTransportType, &transport)
                read(device.id, kAudioDevicePropertyDeviceIsRunningSomewhere, &running)
                if transport != kAudioDeviceTransportTypeAggregate, running != 0 { outcome.failed = true }
            }
        }
        return outcome
    }

    private static func unmute(_ devices: [InputDevice],
                               savedVolumes: [String: Double],
                               savedChannelVolumes: [String: [String: Double]],
                               mutedDevices: [String]?,
                               legacyVolume: Double) -> MuteOutcome {
        let present = devices.map(\.uid)
        var outcome = MuteOutcome(applied: false,
                                  savedVolumes: savedVolumes,
                                  savedChannelVolumes: savedChannelVolumes,
                                  mutedDevices: MicMuteSupport.absentClaims(recorded: mutedDevices,
                                                                            present: present))
        let targets = Set(MicMuteSupport.restoreTargets(recorded: mutedDevices, present: present))
        var attempted = false
        for device in devices where targets.contains(device.uid) {
            // A saved level only leaves once the device really opened: a
            // restore that failed keeps the claim and the level, so the next
            // attempt still knows the device is this app's to release.
            switch MicMuteSupport.restoreNeed(muteSwitch: muteSwitchValue(of: device.id),
                                              volume: inputVolume(of: device.id)) {
            case .alreadyAudible:
                outcome.savedVolumes.removeValue(forKey: device.uid)
                outcome.savedChannelVolumes.removeValue(forKey: device.uid)
            case .unreadable:
                outcome.mutedDevices.append(device.uid)
            case .restore(let clearMute, let restoreVolume):
                attempted = true
                var failed = false
                if clearMute, !setMuteSwitch(false, of: device.id) {
                    failed = true
                }
                if restoreVolume {
                    let restore = MicMuteSupport.volumeToRestore(uid: device.uid,
                                                                 saved: savedVolumes,
                                                                 legacy: legacyVolume)
                    // A channel with no level of its own, as after a mute from
                    // before channels were saved, takes the main level back.
                    if !setInputVolume(restore, of: device.id,
                                       channels: savedChannelVolumes[device.uid] ?? [:]) {
                        failed = true
                    }
                }
                if failed {
                    outcome.mutedDevices.append(device.uid)
                    outcome.failed = true
                } else {
                    outcome.applied = true
                    outcome.savedVolumes.removeValue(forKey: device.uid)
                    outcome.savedChannelVolumes.removeValue(forKey: device.uid)
                }
            }
        }
        // Nothing left silenced is a finished unmute; the user must never be
        // left holding a mute the app refuses to release.
        if !attempted { outcome.applied = true }
        return outcome
    }

    /// True when capture from this device is actually quiet right now. A mute
    /// switch that reads engaged while the level is still live is not enough.
    /// This still does not prove silence in clients that bypass these
    /// controls, such as Siri.
    private static func isSilenced(_ device: AudioDeviceID) -> Bool {
        MicMuteSupport.isCaptureSilenced(muteSwitch: muteSwitchValue(of: device),
                                         volume: inputVolume(of: device))
    }

    /// Every device that can capture audio, skipping the app's own mixing
    /// device and the ones the system is not really offering.
    private static func inputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceIDs) == noErr else { return [] }

        var devices: [InputDevice] = []
        for deviceID in deviceIDs {
            guard hasInputStreams(deviceID) else { continue }

            var isAlive: UInt32 = 1
            if read(deviceID, kAudioDevicePropertyDeviceIsAlive, &isAlive), isAlive == 0 { continue }

            var uidRef: CFString = "" as CFString
            guard read(deviceID, kAudioDevicePropertyDeviceUID, &uidRef) else { continue }
            let uid = uidRef as String
            guard !uid.isEmpty else { continue }

            var nameRef: CFString = "" as CFString
            let name = read(deviceID, kAudioObjectPropertyName, &nameRef) ? nameRef as String : uid
            guard !MicMuteSupport.isOwnDevice(name: name) else { continue }

            devices.append(InputDevice(id: deviceID, uid: uid))
        }
        return devices
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr
            && size >= MemoryLayout<AudioObjectID>.size
    }

    /// How many input channels the device actually has. Used so a mic array
    /// is muted on every element, not just the stereo pair.
    private static func inputChannelCount(of device: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioBufferList>.size) else {
            return MicMuteSupport.minimumChannelCount
        }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else {
            return MicMuteSupport.minimumChannelCount
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func inputElements(of device: AudioDeviceID) -> [AudioObjectPropertyElement] {
        MicMuteSupport.inputChannelElements(channelCount: inputChannelCount(of: device))
    }

    private static func muteAddresses(of device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        inputElements(of: device).map { element in
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                       mScope: kAudioDevicePropertyScopeInput,
                                       mElement: element)
        }
    }

    private static func muteSwitchValue(of device: AudioDeviceID) -> UInt32? {
        var sawProperty = false
        for var address in muteAddresses(of: device) {
            guard AudioObjectHasProperty(device, &address) else { continue }
            sawProperty = true
            var value: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value != 0 {
                return 1
            }
        }
        return sawProperty ? 0 : nil
    }

    /// Every mute control the device exposes, master and channels. Some
    /// drivers answer a write with success and keep their own value, so a
    /// failed read-back is still a write we tried; the volume path is what
    /// makes capture go quiet.
    @discardableResult
    private static func setMuteSwitch(_ muted: Bool, of device: AudioDeviceID) -> Bool {
        var applied = false
        var value: UInt32 = muted ? 1 : 0
        for var address in muteAddresses(of: device) {
            var settable = DarwinBoolean(false)
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            // A failed write on an earlier element must not keep going: some
            // drivers share one switch across channels, and a later success
            // would hide that the control this app relies on stayed put.
            guard AudioObjectSetPropertyData(device, &address, 0, nil,
                                             UInt32(MemoryLayout<UInt32>.size), &value) == noErr else {
                return applied
            }
            applied = true
        }
        return applied
    }

    private static func volumeAddresses(of device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        let elements = inputElements(of: device)
        var addresses = [
            AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                       mScope: kAudioDevicePropertyScopeInput,
                                       mElement: kAudioObjectPropertyElementMain)
        ]
        addresses.append(contentsOf: elements.map { element in
            AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                       mScope: kAudioDevicePropertyScopeInput,
                                       mElement: element)
        })
        return addresses
    }

    private static func inputVolume(of device: AudioDeviceID) -> Float? {
        for var address in volumeAddresses(of: device) where AudioObjectHasProperty(device, &address) {
            var volume = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
                return volume
            }
        }
        return nil
    }

    /// Per-channel levels, keyed by element. A mute lowers them with the main
    /// level, and an unmute that wrote the main level into every channel would
    /// flatten the balance between them.
    private static func channelVolumes(of device: AudioDeviceID) -> [String: Double] {
        var levels: [String: Double] = [:]
        for var address in volumeAddresses(of: device) where address.mElement != kAudioObjectPropertyElementMain
            && AudioObjectHasProperty(device, &address) {
            var volume = Float(0)
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr,
               MicMuteSupport.shouldSaveVolume(volume) {
                levels[String(address.mElement)] = Double(volume)
            }
        }
        return levels
    }

    /// Writes the virtual main level and every input channel, each channel
    /// taking its own entry in `channels` when there is one.
    private static func setInputVolume(_ volume: Float, of device: AudioDeviceID,
                                       channels: [String: Double] = [:]) -> Bool {
        var applied = false
        for var address in volumeAddresses(of: device) where AudioObjectHasProperty(device, &address) {
            var settable = DarwinBoolean(false)
            guard AudioObjectIsPropertySettable(device, &address, &settable) == noErr,
                  settable.boolValue else { continue }
            var value = channels[String(address.mElement)].map(Float.init) ?? volume
            if AudioObjectSetPropertyData(device, &address, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &value) == noErr {
                applied = true
            }
        }
        return applied
    }

    @discardableResult
    private static func read<T>(_ object: AudioObjectID,
                                _ selector: AudioObjectPropertySelector,
                                _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size,
                                       UnsafeMutableRawPointer(pointer)) == noErr
        }
    }

    // MARK: - Listeners

    /// Two changes can defeat an active mute: a device arriving (a headset
    /// connecting mid call) and the default input moving. Both re-assert it,
    /// and both are how a device still owed its level back announces itself.
    private static let watchedSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDevices,
        kAudioHardwarePropertyDefaultInputDevice,
    ]

    private func installListeners() {
        for selector in Self.watchedSelectors where !installedListeners.contains(selector) {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            let status = AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                                        &address, Self.listenerCallback,
                                                        listenerClient)
            if status == noErr {
                installedListeners.append(selector)
            }
        }
    }

    private func removeListeners() {
        for selector in installedListeners {
            var address = AudioObjectPropertyAddress(mSelector: selector,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject),
                                              &address, Self.listenerCallback,
                                              listenerClient)
        }
        installedListeners.removeAll()
    }

    /// The controls an app can move to raise gain again while we are muted.
    /// The virtual main volume is a master-only control; mute and per-channel
    /// volume are watched on every input element we write.
    private static let watchedDeviceSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
        kAudioDevicePropertyMute,
        kAudioDevicePropertyVolumeScalar,
    ]

    /// Runs on `halQueue`. Drops stale device listeners and, while muted,
    /// watches the mute and volume of every input we can see.
    private func syncDeviceListeners(muted: Bool) {
        removeDeviceListeners()
        guard muted else { return }
        for device in Self.inputDevices() {
            let elements = Self.inputElements(of: device.id)
            for selector in Self.watchedDeviceSelectors {
                let watchElements: [AudioObjectPropertyElement]
                if selector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume {
                    watchElements = [kAudioObjectPropertyElementMain]
                } else {
                    watchElements = elements
                }
                for element in watchElements {
                    var address = AudioObjectPropertyAddress(mSelector: selector,
                                                             mScope: kAudioDevicePropertyScopeInput,
                                                             mElement: element)
                    let status = AudioObjectAddPropertyListener(device.id,
                                                                &address,
                                                                Self.listenerCallback,
                                                                listenerClient)
                    if status == noErr {
                        deviceListeners.append(DeviceListener(device: device.id, address: address))
                    }
                }
            }
        }
    }

    private func removeDeviceListeners() {
        for listener in deviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListener(listener.device,
                                              &address,
                                              Self.listenerCallback,
                                              listenerClient)
        }
        deviceListeners.removeAll()
    }
}
