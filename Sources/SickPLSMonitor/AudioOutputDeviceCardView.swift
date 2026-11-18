import SwiftUI
import PlanariumAudio
import SickPLSMonitorKit

struct AudioOutputDeviceCardView: View {
    @ObservedObject var model: AudioOutputDeviceControlModel
    var allowsChanges = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Output", selection: Binding(
                get: { model.selectedDevice.id },
                set: { id in if let device = model.devices.first(where: { $0.id == id }) { model.selectDevice(device) } }
            )) {
                ForEach(model.devices) { device in
                    Text(device.isSystemOutput ? "System Output" : device.name).tag(device.id)
                }
            }
            .disabled(!allowsChanges)
            Picker("Rate", selection: Binding(
                get: { model.currentSampleRate },
                set: { model.setSampleRate($0) }
            )) {
                ForEach(model.availableSampleRates, id: \.self) { rate in
                    Text(Self.rateText(rate)).tag(rate)
                }
            }
            .disabled(!allowsChanges)
            Text("\(Self.rateText(model.currentSampleRate)) · channel processing rate")
                .font(.system(size: 8))
                .foregroundColor(.secondary)
            if model.canRestoreDevice {
                Button("Restore \(model.desiredDevice.name)") { model.restoreDesiredDevice() }
                    .disabled(!allowsChanges)
            }
            if let notice = model.notice {
                Text(notice).font(.system(size: 8)).lineLimit(2)
            }

        }
        .accessibilityIdentifier("strip.audioOutput")
        .padding(10)
        .frame(minWidth: 250, alignment: .leading)
        .background(Color(red: 0.115, green: 0.118, blue: 0.130))
        .foregroundColor(.white.opacity(0.9))
        .colorScheme(.dark)
        .onAppear { model.refresh() }
    }

    private static func rateText(_ rate: Double) -> String {
        rate > 0 ? "\(Int(rate.rounded())) Hz" : "–"
    }
}

/// The same observable output summary is used by every channel strip.
struct AudioOutputStripButton: View {
    @ObservedObject var model: AudioOutputDeviceControlModel
    var showsDevice = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(showsDevice ? model.selectedDevice.name : "Master").lineLimit(1).truncationMode(.middle).font(.system(size: 10, weight: .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 4).padding(.vertical, 3)
            .frame(minHeight: 24).contentShape(Rectangle())
            .foregroundColor(.white.opacity(0.9))
            .background(StudioGlass()).cornerRadius(3)
        }
        .buttonStyle(.plain)
        .help("Master output · click to choose the audio device")
        .accessibilityLabel(showsDevice ? "Master audio device" : "Audio output: Master")
        .accessibilityIdentifier(ChannelStripEntry.audioOutput.accessibilityIdentifier)
    }
}
