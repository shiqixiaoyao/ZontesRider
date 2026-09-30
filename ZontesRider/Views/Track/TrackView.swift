import SwiftUI

// MARK: - 轨迹工段（真实云端轨迹）
//
// 数据源（2026-09-30 实测打通）：
//   GET https://www.ifino.com:8081/zontespkeapp/api
//       /pkeapp/hbaseLocation/selectByCarCodeHbase/<carCode>?startTime=<...>&endTime=<...>
//   时间格式必须是 "yyyy-MM-dd HH:mm:ss"，返回 HBase 轨迹点数组。
//
// 渲染：不引地图 SDK（合规 + 体积），用 Canvas 把经纬度投影成折线，苏维埃描边风格。

@Observable
@MainActor
public final class TrackViewModel {
    public var range: TrackRange = .week
    public var points: [TrackPoint] = []
    public var stats = TrackStats.empty
    public var isLoading = false
    public var errorText: String?
    public var loadedAt: Date?

    public init() {}

    public func load(using auth: AuthStore) async {
        guard auth.isLoggedIn else {
            points = []
            stats = .empty
            errorText = nil
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let pts = try await auth.fetchTrack(range: range)
            points = pts
            stats = TrackStats(points: pts)
            errorText = nil
            loadedAt = Date()
        } catch {
            errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

// MARK: - 主视图

public struct TrackView: View {
    @Environment(AuthStore.self) private var auth
    @State private var viewModel = TrackViewModel()

    // TrackViewModel 是 MainActor 隔离类型，init 必须在主线程上下文求值
    @MainActor public init() {}

    public var body: some View {
        ZStack {
            SovietPalette.castIron.ignoresSafeArea()

            VStack(spacing: 0) {
                HazardStripes()
                SovietBanner("轨迹工段")

                if !auth.isLoggedIn {
                    loginGate
                } else {
                    content
                }

                HazardStripes()
            }
        }
        .preferredColorScheme(.dark)
        .task { await viewModel.load(using: auth) }
        .onChange(of: viewModel.range) { _, _ in
            Task { await viewModel.load(using: auth) }
        }
    }

    // MARK: 内容

    private var content: some View {
        ScrollView {
            VStack(spacing: 14) {
                rangePicker
                plotCard
                statsGrid
                if let e = viewModel.errorText {
                    errorCard(e)
                }
                endpointsCard
                sampleList
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 16)
        }
        .refreshable { await viewModel.load(using: auth) }
    }

    private var loginGate: some View {
        VStack(spacing: 14) {
            Spacer()
            RedStarSeal(size: 52)
            Text("未登记通行")
                .font(.soviet(16))
                .tracking(3)
                .foregroundStyle(SovietPalette.brass)
            Text("轨迹来自 T-Box 上报的历史位置\n请先在「我的」工段登录升仕账号")
                .font(.soviet(11))
                .foregroundStyle(SovietPalette.textMuted)
                .multilineTextAlignment(.center)
                .lineSpacing(4)
            Spacer()
        }
    }

    // MARK: 档位

    private var rangePicker: some View {
        HStack(spacing: 8) {
            ForEach(TrackRange.allCases) { r in
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    viewModel.range = r
                } label: {
                    Text(r.rawValue)
                        .font(.soviet(11))
                        .tracking(1)
                        .foregroundStyle(viewModel.range == r ? SovietPalette.castIron : SovietPalette.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background(viewModel.range == r ? SovietPalette.brass : SovietPalette.steel)
                        .border(SovietPalette.black, width: 2)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: 折线图

    private var plotCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SovietSectionLabel("行驶轨迹")
                Spacer()
                if viewModel.isLoading {
                    ProgressView().controlSize(.small).tint(SovietPalette.brass)
                } else {
                    Text("\(viewModel.points.count) 个轨迹点")
                        .font(.soviet(10))
                        .foregroundStyle(SovietPalette.textFaint)
                }
            }

            TrackPlot(points: viewModel.points)
                .frame(height: 220)
                .background(SovietPalette.steelDark)
                .border(SovietPalette.black, width: 2)
        }
        .padding(14)
        .constructivistCard()
    }

    // MARK: 统计

    private var statsGrid: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                DataCell(label: "轨迹里程",
                         value: String(format: "%.2f", viewModel.stats.distanceKm),
                         unit: "km")
                DataCell(label: "历时",
                         value: String(format: "%.0f", viewModel.stats.durationMinutes),
                         unit: "min")
            }
            HStack(spacing: 10) {
                DataCell(label: "最高车速",
                         value: String(format: "%.0f", viewModel.stats.maxSpeed),
                         unit: "km/h")
                DataCell(label: "平均车速",
                         value: String(format: "%.0f", viewModel.stats.avgSpeed),
                         unit: "km/h")
            }
            HStack(spacing: 10) {
                DataCell(label: "里程表增量",
                         value: viewModel.stats.odometerDelta.map { String(format: "%.1f", $0) } ?? "--",
                         unit: "km")
                DataCell(label: "最后同步",
                         value: viewModel.loadedAt.map { Self.clock.string(from: $0) } ?? "--",
                         unit: nil)
            }
        }
    }

    private var endpointsCard: some View {
        let first = viewModel.points.first
        let last = viewModel.points.last
        return VStack(alignment: .leading, spacing: 8) {
            SovietSectionLabel("起讫点")
            if let first, let last {
                endpointRow("起点", first)
                endpointRow("终点", last)
                if let s = first.timestamp, let e = last.timestamp {
                    Text("\(Self.full.string(from: s)) → \(Self.full.string(from: e))")
                        .font(.soviet(9))
                        .foregroundStyle(SovietPalette.textFaint)
                }
            } else {
                Text("该时间窗内无轨迹点（车辆可能未移动或未上报）")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    private func endpointRow(_ title: String, _ p: TrackPoint) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.soviet(10))
                .foregroundStyle(SovietPalette.textMuted)
                .frame(width: 32, alignment: .leading)
            Text(String(format: "%.5f, %.5f", p.latitude, p.longitude))
                .font(.soviet(11))
                .monospacedDigit()
                .foregroundStyle(SovietPalette.brassPale)
            Spacer()
            if let v = p.voltage {
                Text(String(format: "%.1fV", v))
                    .font(.soviet(10))
                    .foregroundStyle(SovietPalette.textSecondary)
            }
            if let l = p.isLocked {
                Text(l ? "已上锁" : "未上锁")
                    .font(.soviet(10))
                    .foregroundStyle(l ? SovietPalette.ok : SovietPalette.redBright)
            }
        }
    }

    // MARK: 采样点

    private var sampleList: some View {
        let samples = sampled()
        return VStack(alignment: .leading, spacing: 8) {
            SovietSectionLabel("轨迹采样（等距抽取）")
            if samples.isEmpty {
                Text("暂无采样点")
                    .font(.soviet(11))
                    .foregroundStyle(SovietPalette.textMuted)
            } else {
                ForEach(samples) { row in
                    HStack(spacing: 8) {
                        Text(row.point.timestamp.map { Self.clock.string(from: $0) } ?? "--")
                            .font(.soviet(10))
                            .monospacedDigit()
                            .foregroundStyle(SovietPalette.textSecondary)
                        Text(String(format: "%.4f, %.4f", row.point.latitude, row.point.longitude))
                            .font(.soviet(10))
                            .monospacedDigit()
                            .foregroundStyle(SovietPalette.brassPale)
                        Spacer()
                        Text(row.point.speed.map { String(format: "%.0f km/h", $0) } ?? "—")
                            .font(.soviet(10))
                            .foregroundStyle(SovietPalette.textMuted)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .constructivistCard(borderColor: SovietPalette.black)
    }

    /// 最多 8 个等距采样点
    private func sampled() -> [SampleRow] {
        let v = viewModel.points
        guard v.count > 8 else {
            return v.enumerated().map { SampleRow(index: $0.offset, point: $0.element) }
        }
        let step = Double(v.count - 1) / 7
        return (0..<8).compactMap { i in
            let idx = Int((Double(i) * step).rounded())
            return idx < v.count ? SampleRow(index: idx, point: v[idx]) : nil
        }
    }

    private func errorCard(_ msg: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 24))
                .foregroundStyle(SovietPalette.danger)
            Text(msg)
                .font(.soviet(12))
                .foregroundStyle(SovietPalette.danger)
                .multilineTextAlignment(.center)
            Button("重新拉取") { Task { await viewModel.load(using: auth) } }
                .buttonStyle(HeavyMetalButtonStyle())
        }
        .padding(16)
        .constructivistCard(borderColor: SovietPalette.danger)
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

/// 采样行（元组不能做 ForEach 的 id keyPath，包一层）
private struct SampleRow: Identifiable {
    let index: Int
    let point: TrackPoint
    var id: Int { index }
}

// MARK: - 折线绘制（经纬度 → 等比投影）

private struct TrackPlot: View {
    let points: [TrackPoint]

    private struct Box {
        var minLat: Double, maxLat: Double, minLon: Double, maxLon: Double
    }

    var body: some View {
        Canvas { context, size in
            let valid = points.filter { $0.isValid }
            guard let box = Self.box(of: valid), valid.count >= 2 else { return }

            // 背景网格（工业图纸感）
            var grid = Path()
            let step: CGFloat = 24
            var x: CGFloat = 0
            while x < size.width {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
                x += step
            }
            var y: CGFloat = 0
            while y < size.height {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
                y += step
            }
            context.stroke(grid, with: .color(SovietPalette.black.opacity(0.45)), lineWidth: 1)

            // 轨迹折线
            var line = Path()
            for (i, p) in valid.enumerated() {
                let pt = Self.project(p, box: box, size: size)
                if i == 0 { line.move(to: pt) } else { line.addLine(to: pt) }
            }
            context.stroke(line, with: .color(SovietPalette.brass),
                           style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))

            // 起 / 终点标记
            if let first = valid.first {
                let p = Self.project(first, box: box, size: size)
                context.fill(Self.marker(at: p), with: .color(SovietPalette.ok))
            }
            if let last = valid.last {
                let p = Self.project(last, box: box, size: size)
                context.fill(Self.marker(at: p), with: .color(SovietPalette.redBright))
            }
        }
        .overlay(alignment: .topLeading) {
            if points.filter({ $0.isValid }).count < 2 {
                VStack(spacing: 6) {
                    Image(systemName: "point.topleft.down.curvedto.point.bottomright.up")
                        .font(.system(size: 22))
                        .foregroundStyle(SovietPalette.textFaint)
                    Text("该时间窗内无有效轨迹点")
                        .font(.soviet(11))
                        .foregroundStyle(SovietPalette.textMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private static func box(of pts: [TrackPoint]) -> Box? {
        guard let first = pts.first else { return nil }
        var box = Box(minLat: first.latitude, maxLat: first.latitude,
                      minLon: first.longitude, maxLon: first.longitude)
        for p in pts {
            box.minLat = min(box.minLat, p.latitude)
            box.maxLat = max(box.maxLat, p.latitude)
            box.minLon = min(box.minLon, p.longitude)
            box.maxLon = max(box.maxLon, p.longitude)
        }
        return box
    }

    private static func project(_ p: TrackPoint, box: Box, size: CGSize) -> CGPoint {
        let latSpan = max(box.maxLat - box.minLat, 0.0004)
        let lonSpan = max(box.maxLon - box.minLon, 0.0004)
        let pad: CGFloat = 16
        let w = max(size.width - pad * 2, 1)
        let h = max(size.height - pad * 2, 1)
        let fx = (p.longitude - box.minLon) / lonSpan
        let fy = 1 - (p.latitude - box.minLat) / latSpan
        return CGPoint(x: pad + CGFloat(fx) * w, y: pad + CGFloat(fy) * h)
    }

    private static func marker(at p: CGPoint) -> Path {
        Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8))
    }
}

// MARK: - 预览

#Preview("轨迹工段") {
    TrackView()
        .environment(AuthStore())
}
