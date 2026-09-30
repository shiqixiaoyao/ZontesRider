import Foundation

// MARK: - 车况数据源抽象
//
// 仪表盘 / 车况页只认这个协议：
//   未登录 → MockTelemetryProvider（样本数据，可演示 UI）
//   已登录 → CloudTelemetryProvider（getHomeData 真实数据）

public protocol TelemetryProvider: Sendable {
    func fetchTelemetry() async throws -> VehicleTelemetry
}

/// Mock：返回样本数据，时间戳刷新为现在
public struct MockTelemetryProvider: TelemetryProvider {
    public init() {}
    public func fetchTelemetry() async throws -> VehicleTelemetry {
        var t = VehicleTelemetry.sample
        t.updatedAt = Date()
        return t
    }
}

/// 云端：经 AuthStore 取选中车辆的实时车况。
/// AuthStore 是 @MainActor 引用类型，这里只保存弱引用语义上的读取入口。
public struct CloudTelemetryProvider: TelemetryProvider, @unchecked Sendable {
    private let auth: AuthStore

    @MainActor
    public init(auth: AuthStore) {
        self.auth = auth
    }

    public func fetchTelemetry() async throws -> VehicleTelemetry {
        try await auth.fetchHomeData()
    }
}
