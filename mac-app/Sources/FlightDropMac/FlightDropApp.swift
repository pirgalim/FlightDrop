import Foundation
import SwiftUI

struct RouteConfig: Codable, Identifiable {
    let origin: String
    let destination: String
    let currency: String
    let days_ahead: Int
    let trip_type: String
    let date_from: String?
    let date_to: String?
    let return_days: Int?
    let return_date_from: String?
    let return_date_to: String?
    let top_n: Int?

    var id: String {
        let from = date_from ?? ""
        let to = date_to ?? ""
        let stay = return_days.map { String($0) } ?? ""
        let returnFrom = return_date_from ?? ""
        let returnTo = return_date_to ?? ""
        return "\(origin)-\(destination)-\(trip_type)-\(from)-\(to)-\(stay)-\(returnFrom)-\(returnTo)"
    }
}

struct AppConfig: Codable {
    let provider: String
    let routes: [RouteConfig]
}

struct ResultRow: Identifiable {
    let id = UUID()
    let text: String
    let isHeader: Bool
}

final class AppState: ObservableObject {
    @Published var routes: [RouteConfig] = []
    @Published var output: String = ""
    @Published var results: [ResultRow] = []
    @Published var isRunning = false
    @Published var progressText: String = ""
    @Published var progressDeparting: String = ""
    @Published var progressReturn: String = ""
    @Published var progressValue: Double? = nil
    @Published var selectedRouteIds: Set<String> = []
    private var provider: String = "amadeus"
    private var currentProcess: Process?
    private var pendingLine: String = ""
    private var lastResultDateKey: String?

    func loadConfig() {
        guard let configURL = configPath() else {
            output = "config.json not found."
            routes = []
            return
        }
        do {
            let data = try Data(contentsOf: configURL)
            let config = try JSONDecoder().decode(AppConfig.self, from: data)
            provider = config.provider
            routes = config.routes
            selectedRouteIds = Set(config.routes.map { $0.id })
        } catch {
            output = "Failed to read config.json: \(error)"
            routes = []
        }
    }

    func runCheck() {
        guard !isRunning else { return }
        isRunning = true
        output = "Running...\n"
        results = []
        lastResultDateKey = nil
        progressText = "Starting..."
        progressDeparting = ""
        progressReturn = ""
        progressValue = nil

        DispatchQueue.global(qos: .userInitiated).async {
            self.runScript()
        }
    }

    private func runScript() {
        guard let configURL = configPath() else {
            DispatchQueue.main.async {
                self.output = "config.json not found."
                self.isRunning = false
                self.progressText = "Idle"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = nil
            }
            return
        }
        let repoRoot = configURL.deletingLastPathComponent()
        let scriptPath = repoRoot.appendingPathComponent("scripts/flightdrop").path
        if !FileManager.default.isExecutableFile(atPath: scriptPath) {
            DispatchQueue.main.async {
                self.output = "scripts/flightdrop is not executable."
                self.isRunning = false
                self.progressText = "Idle"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = nil
            }
            return
        }

        let selected = routes.filter { selectedRouteIds.contains($0.id) }
        if selected.isEmpty {
            DispatchQueue.main.async {
                self.output = "No routes selected."
                self.isRunning = false
                self.progressText = "Idle"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = nil
            }
            return
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("flightdrop_config.json")
        let tempConfig = AppConfig(provider: provider, routes: selected)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(tempConfig)
            try data.write(to: tempURL, options: .atomic)
        } catch {
            DispatchQueue.main.async {
                self.output = "Failed to write temp config: \(error)"
                self.isRunning = false
                self.progressText = "Idle"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = nil
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-lc", scriptPath]
        var environment = ProcessInfo.processInfo.environment
        environment["FLIGHTDROP_CONFIG"] = tempURL.path
        process.environment = environment

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        currentProcess = process

        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                return
            }
            let chunk = String(data: data, encoding: .utf8) ?? ""
            DispatchQueue.main.async {
                self.consumeOutput(chunk: chunk)
            }
        }

        process.terminationHandler = { _ in
            DispatchQueue.main.async {
                pipe.fileHandleForReading.readabilityHandler = nil
                self.isRunning = false
                self.currentProcess = nil
                self.progressText = "Done"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = 1.0
                if self.output.isEmpty {
                    self.output = "No output from script."
                }
            }
        }

        do {
            try process.run()
        } catch {
            DispatchQueue.main.async {
                self.output = "Failed to start script: \(error)"
                self.isRunning = false
                self.currentProcess = nil
                self.progressText = "Idle"
                self.progressDeparting = ""
                self.progressReturn = ""
                self.progressValue = nil
            }
            return
        }
    }

    private func consumeOutput(chunk: String) {
        if output == "Running...\n" {
            output = ""
        }
        pendingLine.append(chunk)
        let lines = pendingLine.components(separatedBy: "\n")
        pendingLine = lines.last ?? ""
        for line in lines.dropLast() {
            handleLine(line)
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if trimmed.contains("checking ") {
            updateProgress(from: trimmed)
            return
        }
        appendResultLine(trimmed)
    }

    func cancelRun() {
        guard isRunning else { return }
        progressText = "Cancelling..."
        currentProcess?.terminate()
    }

    private func appendResultLine(_ line: String) {
        let departureKey = extractDepartureDateKey(from: line)
        if departureKey != lastResultDateKey {
            lastResultDateKey = departureKey
            if let departureKey, let header = formatShortDate(departureKey) {
                results.append(ResultRow(text: "Departing \(header)", isHeader: true))
            }
        }

        let formatted = prettyLine(line)
        results.append(ResultRow(text: formatted, isHeader: false))
    }

    private func extractDepartureDateKey(from line: String) -> String? {
        let pattern = #"\d{4}-\d{2}-\d{2}"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range),
              let dateRange = Range(match.range, in: line) else {
            return nil
        }
        return String(line[dateRange])
    }

    private func updateProgress(from line: String) {
        let pattern = #"\((\d+)/(\d+)\)"#
        let range = NSRange(line.startIndex..., in: line)
        var current: Double = 0
        var total: Double = 0
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            if let match = regex.firstMatch(in: line, range: range),
               let currentRange = Range(match.range(at: 1), in: line),
               let totalRange = Range(match.range(at: 2), in: line) {
                current = Double(line[currentRange]) ?? 0
                total = Double(line[totalRange]) ?? 0
                if total > 0 {
                    progressValue = min(max(current / total, 0), 1)
                } else {
                    progressValue = nil
                }
            } else {
                progressValue = nil
            }
        }

        let routePart = line.components(separatedBy: ":").first ?? "Route"
        if total > 0 {
            progressText = "\(routePart): checking (\(Int(current))/\(Int(total)))"
        } else {
            progressText = "\(routePart): checking"
        }

        let departPattern = #"Departing\s+([0-9\-]+)"#
        if let departRegex = try? NSRegularExpression(pattern: departPattern, options: []) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = departRegex.firstMatch(in: line, range: range),
               let dateRange = Range(match.range(at: 1), in: line) {
                progressDeparting = prettyLine(String(line[dateRange]))
            }
        }

        let returnPattern = #"Return\s+([0-9\-]+)"#
        if let returnRegex = try? NSRegularExpression(pattern: returnPattern, options: []) {
            let range = NSRange(line.startIndex..., in: line)
            if let match = returnRegex.firstMatch(in: line, range: range),
               let dateRange = Range(match.range(at: 1), in: line) {
                progressReturn = prettyLine(String(line[dateRange]))
            } else {
                progressReturn = ""
            }
        } else {
            progressReturn = ""
        }
    }

    func prettyLine(_ line: String) -> String {
        var rendered = line
        let rangePattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?\s*->\s*\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?"#
        if let regex = try? NSRegularExpression(pattern: rangePattern, options: []) {
            let matches = regex.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: rendered) else { continue }
                let raw = String(rendered[range])
                if let formatted = formatDateTimeRange(raw) {
                    rendered.replaceSubrange(range, with: formatted)
                }
            }
        }
        let isoPattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?"#
        if let regex = try? NSRegularExpression(pattern: isoPattern, options: []) {
            let matches = regex.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: rendered) else { continue }
                let raw = String(rendered[range])
                if let formatted = formatIsoDateTime(raw) {
                    rendered.replaceSubrange(range, with: formatted)
                }
            }
        }

        let datePattern = #"\d{4}-\d{2}-\d{2}"#
        if let regex = try? NSRegularExpression(pattern: datePattern, options: []) {
            let matches = regex.matches(in: rendered, range: NSRange(rendered.startIndex..., in: rendered))
            for match in matches.reversed() {
                guard let range = Range(match.range, in: rendered) else { continue }
                let raw = String(rendered[range])
                if let formatted = formatIsoDate(raw) {
                    rendered.replaceSubrange(range, with: formatted)
                }
            }
        }
        return rendered
    }

    private func formatIsoDateTime(_ value: String) -> String? {
        guard let date = parseIsoDateTime(value) else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d h:mma"
        formatter.amSymbol = "am"
        formatter.pmSymbol = "pm"
        return formatter.string(from: date)
    }

    private func formatDateTimeRange(_ value: String) -> String? {
        let parts = value.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        guard let startDate = parseIsoDateTime(parts[0]),
              let endDate = parseIsoDateTime(parts[1]) else { return nil }

        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let dayDiff = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMMM d"
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mma"
        timeFormatter.amSymbol = "am"
        timeFormatter.pmSymbol = "pm"

        let startString = "\(dateFormatter.string(from: startDate)) \(timeFormatter.string(from: startDate))"
        var endString = timeFormatter.string(from: endDate)
        if dayDiff >= 1 {
            endString += " +\(dayDiff)"
        }
        return "\(startString) -> \(endString)"
    }

    private func parseIsoDateTime(_ value: String) -> Date? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = parser.date(from: value) {
            return parsed
        }
        let fallback = ISO8601DateFormatter()
        if let parsed = fallback.date(from: value) {
            return parsed
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let parsed = formatter.date(from: value) {
                return parsed
            }
        }
        return nil
    }

    private func formatIsoDate(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return nil }
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: date)
    }

    func formatReturnWindow(return_from: String?, return_to: String?) -> String? {
        guard let return_from, let return_to else { return nil }
        let from = prettyLine(return_from)
        let to = prettyLine(return_to)
        return "\(from) -> \(to)"
    }

    func eventLabel(for route: RouteConfig) -> String {
        if let dateTo = route.date_to, let short = formatShortDate(dateTo) {
            return "Event: \(short)"
        }
        let toText = prettyLine(route.date_to ?? "\(route.days_ahead)d")
        return "Event: \(toText)"
    }

    func departDaysText(for route: RouteConfig) -> String {
        let departDays = daysBetween(route.date_from, route.date_to)
        return departDays.map { "\($0)d" } ?? "\(route.days_ahead)d"
    }

    func returnDaysText(for route: RouteConfig) -> String {
        let returnDays = daysBetween(route.date_to, route.return_date_to)
        return returnDays.map { "\($0)d" } ?? "\(route.return_days ?? 0)d"
    }

    func formatShortDate(_ value: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: value) else { return nil }
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    func daysBetween(_ start: String?, _ end: String?) -> Int? {
        guard let start, let end else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let startDate = formatter.date(from: start),
              let endDate = formatter.date(from: end) else {
            return nil
        }
        let calendar = Calendar.current
        let startDay = calendar.startOfDay(for: startDate)
        let endDay = calendar.startOfDay(for: endDate)
        let diff = calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0
        return max(diff, 0)
    }

    private func configPath() -> URL? {
        if let override = ProcessInfo.processInfo.environment["FLIGHTDROP_CONFIG"] {
            return URL(fileURLWithPath: override)
        }

        let fileManager = FileManager.default
        let current = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let local = current.appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: local.path) {
            return local
        }
        let parent = current.appendingPathComponent("..", isDirectory: true)
            .appendingPathComponent("config.json")
        if fileManager.fileExists(atPath: parent.path) {
            return parent
        }
        return nil
    }
}

struct ContentView: View {
    @StateObject private var state = AppState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("FlightDrop")
                    .font(.title)
                Spacer()
                Button("Reload Config") {
                    state.loadConfig()
                }
                Button(state.isRunning ? "Running..." : "Run Selected") {
                    state.runCheck()
                }
                .disabled(state.isRunning)
                Button("Cancel") {
                    state.cancelRun()
                }
                .disabled(!state.isRunning)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)

            GroupBox("Routes") {
                VStack(alignment: .leading, spacing: 0) {
                    if state.routes.isEmpty {
                        Text("No routes loaded.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.vertical, 2)
                    } else {
                        let rowHeight: CGFloat = 72
                        let visibleRows = min(max(state.routes.count, 1), 3)
                        let routes = state.routes
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(routes, id: \.id) { route in
                                    HStack(alignment: .center, spacing: 12) {
                                        VStack(alignment: .leading, spacing: 4) {
                                            let tripLabel = route.trip_type.replacingOccurrences(of: "_", with: " ")
                                            Text("\(route.origin) -> \(route.destination) (\(tripLabel))")
                                                .font(.headline)
                                            Text(state.eventLabel(for: route))
                                                .font(.subheadline)
                                            Text(
                                                "Depart: \(state.departDaysText(for: route)) • Return: \(state.returnDaysText(for: route)) • Top: \(route.top_n ?? 5) • Currency: \(route.currency)"
                                            )
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                        }
                                        .padding(.vertical, 4)

                                        Spacer(minLength: 8)

                                        Toggle("", isOn: Binding(
                                            get: { state.selectedRouteIds.contains(route.id) },
                                            set: { isOn in
                                                var updated = state.selectedRouteIds
                                                if isOn {
                                                    updated.insert(route.id)
                                                } else {
                                                    updated.remove(route.id)
                                                }
                                                state.selectedRouteIds = updated
                                            }
                                        ))
                                        .labelsHidden()
                                        .frame(width: 18)
                                    }
                                }
                            }
                        }
                        .frame(height: rowHeight * CGFloat(visibleRows))
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 8)

            GroupBox("Latest Results") {
                VStack(alignment: .leading, spacing: 0) {
                    if state.results.isEmpty {
                        Text("No results yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 6) {
                                ForEach(state.results) { row in
                                    if row.isHeader {
                                        Text(row.text)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.top, 6)
                                    } else {
                                        Text(row.text)
                                            .font(.system(.body, design: .monospaced))
                                    }
                                }
                            }
                        }
                        .frame(minHeight: 180)
                    }
                }
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 8)

            GroupBox("Progress") {
                VStack(alignment: .leading, spacing: 8) {
                    if let value = state.progressValue {
                        ProgressView(value: value)
                    }
                    Text(state.progressText.isEmpty ? "Idle" : state.progressText)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !state.progressDeparting.isEmpty {
                        Text("Departing: \(state.progressDeparting)")
                            .font(.system(.body, design: .monospaced))
                    }
                    if !state.progressReturn.isEmpty {
                        Text("Return: \(state.progressReturn)")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
            }
            .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
        .padding(.top, 12)
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            state.loadConfig()
        }
    }
}

@main
struct FlightDropMacApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
