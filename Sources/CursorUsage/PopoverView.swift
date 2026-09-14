import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject var store: UsageStore
    var onQuit: () -> Void
    var onDump: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let r = store.report {
                headline(r)
                usageTable(r)
                extras(r)
            } else if let err = store.error {
                errorBox(err)
            } else {
                HStack { ProgressView().controlSize(.small); Text("Loading usage…").foregroundStyle(.secondary) }
                    .padding(.vertical, 24)
            }
            if store.report != nil, let err = store.error {
                errorBox(err)
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
    }

    // MARK: - Sections

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 22, weight: .semibold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 1) {
                Text("Cursor").font(.headline)
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Toggle(isOn: $store.showPercentLeft) { Text("% left") }
                    .help("Show remaining instead of used in the menu bar")
                Toggle(isOn: $store.launchAtLogin) { Text("Login item") }
                    .disabled(!LaunchAtLogin.isAvailable)
                    .help(LaunchAtLogin.isAvailable
                          ? "Start automatically when you log in (also in System Settings → Login Items)"
                          : "Available once installed via make install")
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .font(.caption)
        }
    }

    private var subtitle: String {
        guard let r = store.report else { return "Included usage" }
        let plan = (r.membershipType ?? "plan").capitalized
        return "\(plan) · \(Fmt.cycle(r.cycleStart, r.cycleEnd))"
    }

    private func headline(_ r: UsageReport) -> some View {
        let value = store.showPercentLeft ? r.headlinePercentLeft : r.headlinePercentUsed
        let label = store.showPercentLeft ? "left" : "used"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(Int(value.rounded()))")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("% \(label)").font(.title3).foregroundStyle(.secondary)
            }
            bar(fraction: r.headlinePercentUsed / 100, tint: tint(r.headlinePercentUsed))
            HStack {
                Text("\(Int(r.headlinePercentUsed.rounded()))% used")
                if let used = r.planUsedCents, let limit = r.planLimitCents, limit > 0 {
                    Text("· \(Fmt.usd(cents: Double(used))) of \(Fmt.usd(cents: Double(limit)))")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let end = r.cycleEnd {
                    Text("Resets \(Fmt.resetFmt.string(from: end))")
                        .foregroundStyle(.secondary)
                        .help("in \(Fmt.countdown(to: end))")
                }
            }
            .font(.callout)
        }
    }

    private func usageTable(_ r: UsageReport) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text("Item").frame(maxWidth: .infinity, alignment: .leading)
                Text("Tokens").frame(width: 110, alignment: .trailing)
                Text("Usage").frame(width: 64, alignment: .trailing)
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 10).padding(.vertical, 6)

            ForEach(r.lanes) { lane in
                Divider()
                row(name: lane.lane.rawValue, tokens: lane.tokens, pct: lane.percentUsed, bold: true)
                ForEach(lane.rows) { m in
                    row(name: m.name, tokens: m.tokens, pct: m.percentOfLane, bold: false)
                }
                if lane.rows.isEmpty {
                    Text("No usage yet this period")
                        .font(.caption).foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 4)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }

    private func row(name: String, tokens: Int, pct: Double?, bold: Bool) -> some View {
        HStack {
            Text(name)
                .fontWeight(bold ? .semibold : .regular)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(Fmt.tokens(tokens))
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .frame(width: 110, alignment: .trailing)
            Text(Fmt.percent(pct))
                .monospacedDigit()
                .fontWeight(bold ? .semibold : .regular)
                .frame(width: 64, alignment: .trailing)
        }
        .font(.callout)
        .foregroundStyle(bold ? Color.primary : Color.secondary)
        .padding(.leading, bold ? 10 : 24).padding(.trailing, 10)
        .padding(.vertical, 5)
    }

    private func extras(_ r: UsageReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "creditcard")
                Text("On-demand / extra spend")
                Spacer()
                if r.onDemandEnabled || r.onDemandUsedCents > 0 {
                    Text(Fmt.usd(r.extraSpendUSD)).monospacedDigit().fontWeight(.semibold)
                    if let limit = r.onDemandLimitCents {
                        Text("of \(Fmt.usd(cents: Double(limit)))").foregroundStyle(.secondary)
                    }
                } else {
                    Text("off").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            if !r.onDemandRows.isEmpty {
                ForEach(r.onDemandRows) { m in
                    HStack {
                        Text(m.name).foregroundStyle(.secondary)
                        Spacer()
                        Text(Fmt.tokens(m.tokens)).foregroundStyle(.secondary).monospacedDigit()
                        Text(Fmt.usd(cents: m.chargedCents)).monospacedDigit().frame(width: 64, alignment: .trailing)
                    }
                    .font(.caption).padding(.leading, 22)
                }
            }
            HStack {
                Text("\(r.eventCount) events · lanes by \(r.laneRule)")
                Spacer()
                Text("Updated \(Fmt.timeFmt.string(from: r.fetchedAt))")
            }
            .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private func errorBox(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(msg).font(.callout).textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    private var footer: some View {
        HStack {
            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isRefreshing)
            Spacer()
            Button("Dump JSON", action: onDump).help("Write raw API responses to ~/Library/Logs/CursorUsage for debugging")
            Button("Dashboard") {
                NSWorkspace.shared.open(URL(string: "https://cursor.com/dashboard?tab=usage")!)
            }
            Button("Quit", action: onQuit)
        }
        .buttonStyle(.borderless)
        .font(.callout)
    }

    // MARK: - Bits

    private func bar(fraction: Double, tint: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: max(6, geo.size.width * min(1, max(0, fraction))))
            }
        }
        .frame(height: 8)
    }

    private func tint(_ pctUsed: Double) -> Color {
        pctUsed >= 90 ? .red : pctUsed >= 70 ? .orange : .green
    }
}
