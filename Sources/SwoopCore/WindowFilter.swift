/// Decides which windows belong in the switcher.
public enum WindowFilter {
    public static let minimumWidth = 100.0
    public static let minimumHeight = 50.0

    /// Windows on any other layer are menus, panels and overlays.
    public static func isSubstantial(layer: Int, width: Double, height: Double) -> Bool {
        layer == 0 && width >= minimumWidth && height >= minimumHeight
    }

    /// Takes the Accessibility role and subrole. Palettes, sheets and popovers
    /// are windows too, but aren't things you'd switch to.
    public static func isSwitchable(role: String?, subrole: String?) -> Bool {
        guard role == "AXWindow" else { return false }
        return subrole == "AXStandardWindow" || subrole == "AXDialog"
    }
}
