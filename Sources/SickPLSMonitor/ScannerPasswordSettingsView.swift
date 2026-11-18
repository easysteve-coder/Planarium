import SwiftUI
import SickPLSCommissioningControl

/// Die App-Einstellungen für das **Scanner-Passwort** (SICK-032a2).
///
/// **Eine gewöhnliche Einstellung.** Der Wert steht im Klartext da, ist
/// jederzeit direkt bearbeitbar und wird beim Tippen gespeichert;
/// „Vergessen" löscht ihn. Kein Maskieren, kein zusätzlicher Klick zum
/// Anzeigen, kein Schlüsselbund.
///
/// **Reine Komposition:** Der Hinweistext kommt aus
/// ``ScannerPasswordSettingsModel``, nicht von hier.
struct ScannerPasswordSettingsView: View {

    @ObservedObject var model: ScannerPasswordSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scanner password")
                .font(.headline)

            Text("The password the app uses to log in when reconfiguring the scanner. "
                 + "It is documented in the scanner manual.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("Scanner password", text: $model.password)
                .textFieldStyle(.roundedBorder)

            Text(model.hint)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Forget") { model.forget() }
                    .disabled(model.password.isEmpty)
                Spacer()
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .stageSettings()
        .onAppear { model.refresh() }
    }
}
