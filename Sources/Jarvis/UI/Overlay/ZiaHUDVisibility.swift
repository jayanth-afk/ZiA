import SwiftUI

/// Tracks whether the voice HUD is actually on screen.
///
/// The presence is the most expensive thing ZiA draws, so it must never render
/// while the HUD is hidden. Publishing visibility lets every animated surface
/// freeze to a still frame instead of burning frames off-screen.
@MainActor
public final class ZiaHUDVisibility: ObservableObject {
    public static let shared = ZiaHUDVisibility()

    @Published public private(set) var isVisible: Bool = false

    private init() {}

    func update(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
    }
}
