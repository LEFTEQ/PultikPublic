import Foundation

/// How far back Now looks: a rolling day ending now (copilot shell D12). The
/// Handled section, eve's notifications and the fleet's sessions forget what
/// is older. The Now Line that drew this window as an axis retired
/// 2026-10-15 (vt-7727 D7/D8); the window stayed.
enum NowWindow {
    static let span: TimeInterval = 24 * 3600
}
