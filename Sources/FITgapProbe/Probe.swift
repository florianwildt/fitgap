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
        switch CommandLine.arguments.dropFirst().first {
        case "zwift" where CommandLine.arguments.count == 2: await run(zwift)
        case "mywhoosh" where CommandLine.arguments.count == 2: await run(mywhoosh)
        default: print("FITgap Phase 1 – experimenteller lokaler Kontotest\nAufruf: fitgap-probe zwift | mywhoosh")
        }
    }

    static func zwift() async throws {
        let client = ZwiftProbe()
        defer { client.close() }
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
    }

    static func mywhoosh() async throws {
        let client = MyWhooshProbe()
        defer { client.close() }
        print("Inoffizielle MyWhoosh-Schnittstelle. Nur eigenes Konto verwenden.\nEingaben bleiben unsichtbar; keine Speicherung von Zugangsdaten oder Tokens.")
        let session = try await client.authenticate(username: input("MyWhoosh E-Mail: "), password: input("MyWhoosh Passwort: "))
        print("Anmeldung erfolgreich. Erste Seite der Aktivitätsliste …")
        let first = try await client.page(1, session: session)
        print("HTTP 200, \(first.itemCount) Einträge\nAntwortstruktur (nur Feldnamen und Typen): \(first.shape)")
        guard first.activities != nil else { throw ProbeError.invalidResponse }
        print("Aktivitäten werden seitenweise gelesen …")
        let activities = try await client.activities(session: session) { number, page in
            print("Seite \(number)\(page.totalPages.map { " von \($0)" } ?? ""): \(page.itemCount) Einträge")
            if page.activities == nil { print("Antwortstruktur: \(page.shape)") }
        }
        print("\(activities.count) eindeutige Aktivitäten gelesen. Die neuesten 20:")
        for activity in activities.prefix(20) {
            print("\(activity.id) | \(activity.start?.ISO8601Format() ?? "Datum unbekannt") | \(activity.name) | \(activity.fileID != nil ? "FIT" : "keine FIT")")
        }
        guard let activity = activities.first(where: { $0.fileID != nil }) else { throw ProbeError.noFIT }
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".local/validation/mywhoosh", isDirectory: true)
        let (receipt, host) = try await client.download(activity, session: session, store: OriginalFITStore(directory: directory))
        print("Signierter Downloadlink von Host \(host) ohne API-Token geladen.")
        print("Originale Downloadbytes gespeichert: \(receipt.byteCount) Bytes\nSHA-256: \(receipt.sha256)\nDatei: \(directory.appendingPathComponent(activity.key.filename).path)")
        print("Kontotest abgeschlossen. FIT-Header und Länge geprüft; kein CRC-, Geräte- oder HealthFit-Importtest.")
    }

    static func run(_ probe: () async throws -> Void) async {
        do {
            try await probe()
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
