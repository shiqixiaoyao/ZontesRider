import Foundation
import CoreLocation

// MARK: - 坐标系纠偏（国内地图必备）
//
// 为什么必须有这个：
//   车辆 T-Box / GPS 上报的是 **WGS-84**（GPS 原始坐标），
//   而国内所有合法地图底图（iOS 中国区 MapKit 用高德数据）都是 **GCJ-02**（火星坐标）。
//   两者相差约 50~500 米，直接把 WGS-84 的轨迹画在 GCJ-02 底图上，
//   折线会整体平移到旁边（看着像"车开进了河里/楼里"）—— 这就是必须用纠偏的原因。
//
// 算法是公开的 GCJ-02 加密偏移（非线性加偏），中国境外不做处理。

public enum GeoTransform {
    private static let pi = Double.pi
    /// 克拉索夫斯基椭球长半轴
    private static let a = 6_378_245.0
    /// 第一偏心率平方
    private static let ee = 0.006_693_421_622_965_943

    /// 是否在中国境外（境外不需要纠偏）
    public static func outOfChina(lat: Double, lon: Double) -> Bool {
        if lon < 72.004 || lon > 137.8347 { return true }
        if lat < 0.8293 || lat > 55.8271 { return true }
        return false
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * pi) + 40.0 * sin(y / 3.0 * pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * pi) + 320.0 * sin(y * pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * pi) + 20.0 * sin(2.0 * x * pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * pi) + 40.0 * sin(x / 3.0 * pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * pi) + 300.0 * sin(x / 30.0 * pi)) * 2.0 / 3.0
        return ret
    }

    /// WGS-84（GPS 原始）→ GCJ-02（国内地图底图坐标系）
    public static func wgs84ToGcj02(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        guard !outOfChina(lat: lat, lon: lon) else { return (lat, lon) }

        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)

        let radLat = lat / 180.0 * pi
        var magic = sin(radLat)
        magic = 1 - ee * magic * magic
        let sqrtMagic = sqrt(magic)

        dLat = (dLat * 180.0) / ((a * (1 - ee)) / (magic * sqrtMagic) * pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * pi)

        return (lat + dLat, lon + dLon)
    }
}

// MARK: - 轨迹坐标批转换

public extension GeoTransform {
    /// 把轨迹点批量转成地图坐标（带坐标系开关，便于用户对照纠偏效果）
    static func coordinates(of points: [TrackPoint], gcj02: Bool) -> [CLLocationCoordinate2D] {
        points.filter { $0.isValid }.map { p in
            if gcj02 {
                let t = wgs84ToGcj02(lat: p.latitude, lon: p.longitude)
                return CLLocationCoordinate2D(latitude: t.lat, longitude: t.lon)
            }
            return CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        }
    }
}
