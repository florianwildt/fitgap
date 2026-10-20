import Darwin
import FITgapCore
import Foundation

@main
struct Probe {
    static func input(_ prompt: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        defer { buffer.withUnsafeMutableBufferPointer { $0.update(repeating: 0) } }
        guard readpassphrase(prompt, &buffer, buffer.count, RPP_REQUIRE_TTY | RPP_ECHO_OFF) != nil else {
            throw ProbeError.terminal
        }
        let value = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard !value.isEmpty else { throw ProbeError.terminal }
        return value
    }

    static func main() async {
        guard CommandLine.arguments == [CommandLine.arguments[0], "zwift"] else {
            print("FITgap Phase 1 – experimenteller lokaler Kontotest\nAufruf: fitgap-probe zwift")
            return
        }
        let client = ZwiftProbe()
        defer { client.close() }
        do {
            print("Inoffizielle Zwift-Schnittstelle. Nur eigenes Konto verwenden.\nEingaben bleiben unsichtbar; keine Speicherung von Zugangsdaten oder Tokens.")
            let token = try await client.authenticate(username: input("Zwift E-Mail: "), password: input("Zwift Passwort: "))
            print("Anmeldung erfolgreich. Aktivitäten werden seitenweise gelesen …")
            let activities = try await client.activities(token: token)
            print("\(activities.count) eindeutige Aktivitäten gelesen. Die neuesten 20:")
            for activity in activities.prefix(20) {
                print("\(activity.id) | \(activity.startDate ?? "Datum unbekannt") | \(activity.name)")
            }
            guard let activity = activities.first(where: { $0.downloadURL != nil }) else { throw ProbeError.noFIT }
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(".local/validation/zwift", isDirectory: true)
            let receipt = try await client.download(activity, store: OriginalFITStore(directory: directory))
            print("Originale Downloadbytes gespeichert: \(receipt.byteCount) Bytes\nSHA-256: \(receipt.sha256)\nDatei: \(directory.appendingPathComponent(activity.key.filename).path)")
            print("Kontotest abgeschlossen. FIT-Header und Länge geprüft; kein CRC-, Geräte- oder HealthFit-Importtest.")
        } catch let error as ProbeError {
            print("Prüfung gestoppt: \(error.localizedDescription)")
            exit(1)
        } catch is CancellationError {
            print("Prüfung abgebrochen.")
            exit(1)
        } catch let error as URLError {
            // Never print request URLs, response bodies, credentials or signed storage links.
            print("Netzwerkfehler (Code \(error.code.rawValue)). Verbindung prüfen; keine erfolgreiche Kontovalidierung.")
            exit(1)
        } catch {
            print("Lokaler Lese-/Speicherfehler. Keine erfolgreiche Kontovalidierung.")
            exit(1)
        }
    }
}
