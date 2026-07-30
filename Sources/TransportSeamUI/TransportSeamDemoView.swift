// The SwiftUI surface is compiled only where SwiftUI exists. This lets the
// package's logic build and test headlessly on Linux CI while the same
// checkout still produces a real iOS app in Demo.xcodeproj.
#if canImport(SwiftUI)
import SwiftUI
import TransportSeam

/// Scenarios differ only in which transport is plugged in. `ServiceStatusClient`
/// is constructed identically in every case.
public enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
    case healthy
    case flakyUpstream
    case unrouted

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .healthy: return "Healthy"
        case .flakyUpstream: return "Flaky (2 × 500)"
        case .unrouted: return "No route"
        }
    }

    public var explanation: String {
        switch self {
        case .healthy:
            return "In-process loopback server answers on the first attempt."
        case .flakyUpstream:
            return "Upstream fails twice with 500. Retry middleware recovers it — the feature code never learns."
        case .unrouted:
            return "Server has no matching route, so the client surfaces a 404 instead of crashing."
        }
    }
}

@MainActor
@Observable
public final class TransportSeamDemoModel {
    public private(set) var statuses: [ServiceStatus] = []
    public private(set) var logEntries: [TransportLogEntry] = []
    public private(set) var errorText: String?
    public private(set) var isLoading = false
    public private(set) var acknowledgement: String?

    public var scenario: DemoScenario = .healthy

    /// The `??` branch is unreachable for this compile-time-constant string; it
    /// is here so the file contains no force-unwraps at all.
    private let baseURL = URL(string: "https://status.example.com/v1")
        ?? URL(fileURLWithPath: "/status")

    /// `nonisolated` on purpose. SwiftUI initialises `@State` in a nonisolated
    /// context, so a `@MainActor`-isolated initialiser here fails to type-check
    /// under Swift 6 strict concurrency. Every stored property below is
    /// `Sendable`, which is what makes this legal.
    public nonisolated init() {}

    private func makeTransport(log: TransportLog) -> any HTTPTransport {
        let routes: [LoopbackTransport.Route: HTTPResponse] = [
            .init(method: .get, path: "/v1/status"): StatusFixtures.okResponse,
            .init(method: .post, path: "/v1/incidents/media/ack"): HTTPResponse(status: HTTPStatus(202))
        ]

        let origin: any HTTPTransport
        switch scenario {
        case .healthy:
            origin = LoopbackTransport(routes: routes)
        case .flakyUpstream:
            origin = FlakyTransport(base: LoopbackTransport(routes: routes), failures: 2)
        case .unrouted:
            origin = LoopbackTransport(routes: [:])
        }

        // Composition root: the one place that names a concrete transport.
        return origin.wrapped(in: [
            RetryMiddleware(
                policy: RetryPolicy(maxAttempts: 3, baseDelay: .milliseconds(120)),
                jitter: FixedJitter(1)
            ),
            LoggingMiddleware(log: log),
            DefaultFieldsMiddleware([("X-Client", "TransportSeamDemo")])
        ])
    }

    public func load() async {
        isLoading = true
        errorText = nil
        acknowledgement = nil
        statuses = []

        let log = TransportLog()
        let client = ServiceStatusClient(baseURL: baseURL, transport: makeTransport(log: log))

        do {
            statuses = try await client.fetchStatuses()
        } catch let error as HTTPStatusError {
            errorText = "HTTP \(error.status) — handled, not crashed."
        } catch let error as TransportError {
            errorText = "Transport error: \(error)"
        } catch {
            errorText = "Unexpected: \(error)"
        }

        logEntries = await log.snapshot()
        isLoading = false
    }

    /// A write. It carries an idempotency key, which is the only reason the same
    /// retry middleware is willing to re-send it.
    public func acknowledgeMediaIncident() async {
        isLoading = true
        errorText = nil

        let log = TransportLog()
        let client = ServiceStatusClient(baseURL: baseURL, transport: makeTransport(log: log))

        do {
            let status = try await client.acknowledge(incidentID: "media", idempotencyKey: "ack-media-1")
            acknowledgement = "Acknowledged — HTTP \(status)"
        } catch let error as HTTPStatusError {
            errorText = "Acknowledge failed with HTTP \(error.status)."
        } catch {
            errorText = "Acknowledge failed: \(error)"
        }

        logEntries = await log.snapshot()
        isLoading = false
    }
}

public struct TransportSeamDemoView: View {
    @State private var model = TransportSeamDemoModel()

    public init() {}

    public var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Transport", selection: $model.scenario) {
                        ForEach(DemoScenario.allCases) { scenario in
                            Text(scenario.title).tag(scenario)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(model.scenario.explanation)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Swap the transport")
                } footer: {
                    Text("ServiceStatusClient is built the same way in all three cases. It never names a transport.")
                }

                Section("Service status") {
                    if model.statuses.isEmpty && model.errorText == nil {
                        Text(model.isLoading ? "Loading…" : "Tap Send to run the request.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.statuses) { status in
                        StatusRow(status: status)
                    }

                    if let errorText = model.errorText {
                        Label(errorText, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }

                    if let acknowledgement = model.acknowledgement {
                        Label(acknowledgement, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                            .font(.callout)
                    }
                }

                Section {
                    if model.logEntries.isEmpty {
                        Text("No attempts recorded yet.")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(model.logEntries) { entry in
                        LogRow(entry: entry)
                    }
                } header: {
                    Text("Physical attempts")
                } footer: {
                    Text("One line per real send. Retries appear here and nowhere else in the app.")
                }
            }
            .navigationTitle("Transport Seam")
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                        Task { await model.load() }
                    } label: {
                        Label("Send GET", systemImage: "arrow.down.circle")
                    }
                    .disabled(model.isLoading)

                    Spacer()

                    Button {
                        Task { await model.acknowledgeMediaIncident() }
                    } label: {
                        Label("POST ack", systemImage: "checkmark.circle")
                    }
                    .disabled(model.isLoading)
                }
            }
        }
    }
}

private struct StatusRow: View {
    let status: ServiceStatus

    var body: some View {
        HStack {
            Circle()
                .fill(color)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(status.name)
                    .font(.body)
                Text(status.state.rawValue.capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(status.latencyMilliseconds > 0 ? "\(status.latencyMilliseconds) ms" : "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var color: Color {
        switch status.state {
        case .operational: return .green
        case .degraded: return .yellow
        case .outage: return .red
        }
    }
}

private struct LogRow: View {
    let entry: TransportLogEntry

    var body: some View {
        HStack(spacing: 10) {
            Text("#\(entry.attempt)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)

            Text("\(entry.method.rawValue) \(entry.path)")
                .font(.caption.monospaced())
                .lineLimit(1)

            Spacer()

            switch entry.outcome {
            case .completed(let status):
                Text(status.description)
                    .font(.caption.monospacedDigit().bold())
                    .foregroundStyle(status.isSuccess ? Color.green : Color.orange)
            case .failed:
                Text("ERR")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
        }
    }
}

#Preview {
    TransportSeamDemoView()
}

#endif
