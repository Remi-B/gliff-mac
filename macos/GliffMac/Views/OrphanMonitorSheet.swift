import GliffCore
import SwiftUI

extension View {
    /// Offers the host's orphaned virtual monitors in a sheet on this window.
    func orphanMonitorSheet(controller: SessionController) -> some View {
        modifier(OrphanMonitorSheetModifier(controller: controller, monitors: controller.monitors))
    }
}

private struct OrphanMonitorSheetModifier: ViewModifier {
    let controller: SessionController
    @ObservedObject var monitors: OrphanMonitors

    func body(content: Content) -> some View {
        content.sheet(
            item: Binding(get: { monitors.offer }, set: { if $0 == nil { monitors.dismissOffer() } })
        ) { offer in
            OrphanMonitorSheet(monitors: monitors, offer: offer)
                // Keys typed in the sheet must stay on this Mac.
                .onAppear { controller.releaseInput() }
        }
    }
}

/// Remove or Ignore, then the result per monitor.
struct OrphanMonitorSheet: View {
    @ObservedObject var monitors: OrphanMonitors
    let offer: OrphanMonitors.Offer

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            Text(explanation)
                .fixedSize(horizontal: false, vertical: true)
            List(offer.outputs, id: \.name) { output in
                HStack {
                    Image(systemName: "rectangle.dashed")
                        .accessibilityHidden(true)
                    Text(output.name)
                        .monospaced()
                    Spacer()
                    Text(Self.detail(output, result: result(for: output)))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(minHeight: 60, idealHeight: CGFloat(min(offer.outputs.count, 6)) * 28 + 12)
            footer
        }
        .padding(20)
        .frame(width: 460)
    }

    /// The offer as it progresses: the sheet's item keeps its first value.
    private var current: OrphanMonitors.Offer { monitors.offer.flatMap { $0.id == offer.id ? $0 : nil } ?? offer }

    private var title: String {
        let count = offer.outputs.count
        return "\(count) orphaned virtual \(count == 1 ? "monitor" : "monitors") on \(offer.host)"
    }

    private var explanation: String {
        """
        Gliff servers that no longer run left \(offer.outputs.count == 1 ? "this monitor" : "these monitors") \
        on the host. \(offer.outputs.count == 1 ? "It is" : "They are") invisible, but Hyprland can still put \
        workspaces and windows there.
        """
    }

    @ViewBuilder private var footer: some View {
        switch current.step {
        case .asking:
            Text(Self.removalNote(count: offer.outputs.count))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Ignore", role: .cancel) { monitors.ignoreOffered() }
                    .keyboardShortcut(.cancelAction)
                    .help("Keep them; this window will not ask again")
                Button("Remove") { monitors.removeOffered() }
                    .keyboardShortcut(.defaultAction)
            }
        case .removing:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Removing…")
                Spacer()
            }
        case .finished(let results):
            Text(OrphanMonitors.summary(.finished(results)))
                .font(.footnote)
            done
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .fixedSize(horizontal: false, vertical: true)
            done
        }
    }

    private var done: some View {
        HStack {
            Spacer()
            Button("Done") { monitors.dismissOffer() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func result(for output: OrphanedOutput) -> RemovalOutcome? {
        guard case .finished(let results) = current.step else { return nil }
        return results.first { $0.name == output.name }?.outcome
    }

    /// Verified live on Hyprland 0.56: a removed headless output's workspaces,
    /// and their windows, move to a remaining monitor.
    static func removalNote(count: Int) -> String {
        count == 1
            ? "Removing it moves its workspaces and windows to another monitor; nothing is closed."
            : "Removing them moves their workspaces and windows to another monitor; nothing is closed."
    }

    static func detail(_ output: OrphanedOutput, result: RemovalOutcome?) -> String {
        if let result {
            return switch result {
            case .removed: "Removed"
            case .inUse: "In use again, kept"
            case .failed: "Could not be removed"
            }
        }
        let size = output.width > 0 && output.height > 0 ? "\(output.width)×\(output.height)" : "Size unknown"
        return output.enabled ? size : "\(size), disabled"
    }
}

/// The automatic setting's short status, in the session's status bar.
struct OrphanMonitorNotice: View {
    @ObservedObject var monitors: OrphanMonitors

    var body: some View {
        if let notice = monitors.notice {
            Label(notice, systemImage: "rectangle.badge.xmark")
                .lineLimit(1)
                .help("Virtual monitors left by Gliff servers that no longer run (Settings › Virtual monitors).")
        }
    }
}
