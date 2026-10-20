# Arbeitsregeln

## Kommunikation und Auftrag

- Kurz, präzise und ohne Wiederholungen kommunizieren.
- Reine Prüfaufträge: nur lesen, analysieren und berichten; keine Dateien ändern.
- Beauftragte Arbeiten eigenständig bis zum überprüfbaren Ergebnis durchführen. Nur notwendige Angaben erfragen.
- Keine Browsersteuerung. Erforderliche manuelle Einrichtungs- und Veröffentlichungsschritte samt Kopiertexten vollständig im Chat bereitstellen.
- Keine separaten Testanleitungen oder Anleitungsdateien erstellen, sofern nicht ausdrücklich gewünscht.
- Commit und Push nur nach ausdrücklichem Auftrag; nach lokal geprüften Änderungen empfehlen.
- Ausdrückliche Nutzerabschlüsse für den genannten Umfang einschließlich Prüf-, Einrichtungs- und Betriebsaufgaben anerkennen. Historische Nachweise unverändert erhalten.

## Umsetzung und Oberfläche

- Bestehende Architektur, Projektkonventionen und vorhandene Komponenten zuerst prüfen und wiederverwenden.
- Änderungen auf den beauftragten Umfang begrenzen. Keine beiläufigen Umbauten oder zusätzlichen Abhängigkeiten.
- Native Komponenten und offizielle Plattform-APIs bevorzugen; eigene Controls, Wrapper und Bibliotheken nur mit konkreter Begründung einsetzen.
- Bei Layoutänderungen Texte, Hinweise, Links und Bedienelemente vollständig erhalten, sofern keine Inhaltsänderung beauftragt ist. Sichtbarkeit und Erreichbarkeit prüfen.
- Neue und überarbeitete Oberflächen für die unterstützten Farbschemata, Bildschirmgrößen und Bedienformen auslegen.
- Lesbare Kontraste, adaptive Farben, verständliche Symbole, Accessibility-Beschriftungen und ausreichend große Bedienflächen sicherstellen.
- Vergleichbare Module app-weit bei Rändern, Abständen, Ausrichtung und Trennlinien vereinheitlichen. Innenabstände und reservierte Bedienflächen zusammen prüfen.
- Umfangreiche Auswahlen möglichst mit integrierter Suche anbieten.
- Bestehende Konventionen für Sprache, Datum, Kalender, Zahlen, Währungen und Sortierung durchgängig einhalten.
- Technische Implementierungsdetails nur dann in der Oberfläche zeigen, wenn sie Nutzern bei einer Entscheidung helfen.

## Daten, Sicherheit und Ressourcen

- Datenbankzugriffe, Speicher, Netzwerkverkehr und Hintergrundarbeit sparsam einsetzen.
- Vorhandene Ressourcen- und Tarifgrenzen berücksichtigen; aktuelle Konditionen bei entscheidungsrelevanten Änderungen prüfen.
- Geheimnisse und Zugangsdaten niemals ausgeben, einchecken oder in App-Artefakte übernehmen.
- Bestehende Berechtigungen, Zugriffskontrollen und Datenschutzanforderungen erhalten.
- Datenverlust, destruktive Migrationen und irreversible Aktionen vorher ausdrücklich abstimmen.
- Bei Datenmodelländerungen Kompatibilität, Migration und Wiederherstellung berücksichtigen.

## Effiziente Fehlerbehebung und Prüfung

- Vor Änderungen wenige konkrete Erfolgskriterien einschließlich der zugesagten Funktionen festlegen.
- Kleine Korrekturen auf die belegte Ursache und betroffene Aufrufstellen begrenzen. Nur bei nachgewiesenem Zusammenhang weiter untersuchen.
- Pro Lösungsvariante eine konkrete Ursachenhypothese prüfen. Vor Folgeänderungen vorhandene Messwerte, Screenshots und Laufzeitnachweise auswerten.
- Keine spekulativen Serien von Layout-, Konfigurations- oder Codeänderungen durchführen.
- Nach zwei erfolglosen Varianten oder zehn Minuten ohne nachweisbaren Fortschritt den Ansatz anhand offizieller Dokumentation und verfügbarer Diagnosewerkzeuge überprüfen.
- Bei belegten Grenzen einer Komponente früh eine geeignete offizielle Alternative prüfen.
- Mit der kleinsten aussagekräftigen Prüfung beginnen. Bestehende Tests wiederverwenden und konkrete Regressionstests bei Bedarf ergänzen.
- Tests nach Risiko und Auswirkung auswählen; keine Tests ergänzen, die lediglich die Implementierung nachbilden.
- UI-Testfehler nach Produktfehler, Bedienung, Selektor und Umgebung unterscheiden. Vor Änderungen oder Wiederholungen Hierarchie und Aufnahmen auswerten.
- Unterstützte Farbschemata, relevante Bildschirmgrößen und betroffene Abläufe abschließend gebündelt prüfen.
- Bestandene Prüfungen nur bei relevanten Änderungen, neuen Fehlern oder offenen Befunden wiederholen.
- Testumgebungen, Fixtures und Build-Caches wiederverwenden. Unabhängige Prüfungen bei ausreichenden Ressourcen parallel ausführen; gemeinsam genutzte Testdaten dabei unverändert lassen.
- Nach der letzten Codeänderung einen lokalen Release- oder Produktionsbuild ausführen. Reine Dokumentationsänderungen nur per Diff prüfen.

## Builds und Releases

- Neue Releases und Versionserhöhungen vorher abstimmen; bereits beauftragte Releases fortführen.
- Versionen und Buildnummern in den zuständigen Projektdateien konsistent pflegen.
- Lokale Builds selbst ausführen. Cloud- oder Store-Builds, Uploads, Einreichungen und Veröffentlichungen ausschließlich manuell durch den Nutzer durchführen lassen.
- Beim App- oder Buildabschluss Version und Buildnummer nennen. Lokale Ergebnisse und Cloud-/Store-Ergebnisse getrennt dokumentieren.
- Automatisch vergebene Buildnummern berücksichtigen. Bestätigte Cloud-/Store-Nummern unverändert verwenden; nur fehlende oder widersprüchliche Angaben klären.
- Keine zusätzlichen Builds allein zur Angleichung von Buildnummern auslösen.
- Externe Build- und Veröffentlichungsstände nur lesend prüfen. Laufstatus, Upload und Verarbeitung getrennt bewerten; bestätigte Nutzerangaben bei verzögerten Schnittstellen berücksichtigen.
- Release Notes bei Änderungen des freigegebenen Umfangs aktualisieren: nur umgesetzte Funktionen und kurze Nutzenbeschreibungen, keine internen Entwicklungsdetails oder leeren Rubriken.
- Fehlerbehebungen nur dann als solche ausweisen, wenn sie frühere veröffentlichte Versionen betreffen. Entwicklungskorrekturen einer neuen Funktion dieser Funktion zuordnen.
- Bekannte Inkompatibilitäten und erforderliche Updates mit betroffenen Versionen benennen.

## Dokumentation

- Bereits bekannte Regeln nur bei Änderungen oder Unklarheiten erneut lesen.
- Projektdokumentation gezielt über Überschriften und Suche in kurzen Ausschnitten lesen. Historie nur bei konkretem Bedarf heranziehen.
- Vorhandene Dokumentationsstruktur verwenden; keine parallelen Ablagen für dieselben Informationen anlegen.
- Informationen ausschließlich in der zuständigen Datei pflegen und andernorts darauf verlinken:
  - README: Projekt, Architektur, Funktionen und aktueller bestätigter Release-/Prüfstand mit Nachweislinks.
  - Prüfhistorie: datierte Prüf-, Build- und Abnahmenachweise je Version oder Thema.
  - Aufgabenliste: ausschließlich offene oder zurückgestellte Aufgaben; Erledigtes entfernen.
  - AGENTS.md: Arbeitsregeln.
  - Release Notes: umgesetzter Umfang der jeweiligen Version.
- Historische Nachweise mit Datum, Umfang, Abnahmen, Version/Build, Ergebnissen, Nachweispfaden und damaligen Grenzen erhalten.
- Keine fortlaufenden Arbeitsprotokolle in der README und keine einzelnen Nachweisdateien für jede kleine Prüfung anlegen.
- Historische Archive und Release-Dokumente behalten ihren ursprünglichen Zeit- und Versionsbezug.

## Werkzeuge und Abschluss

- Datei- und Textsuche gezielt durchführen; unabhängige Leseprüfungen bündeln.
- Werkzeugausgaben begrenzen und lange Build-/Testprotokolle in Dateien sichern.
- Exitstatus, relevante Warnungen und Befunde stets auswerten.
- Im Abschluss knapp nennen: Ergebnis, durchgeführte Prüfungen und verbleibende Einschränkungen. Bei Builds zusätzlich Version und Buildnummer angeben.
- Nicht ausgeführte oder nicht mögliche Prüfungen ausdrücklich kennzeichnen. Erfolg nur bei vorhandenem Nachweis bestätigen.