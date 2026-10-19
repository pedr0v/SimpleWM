import ApplicationServices
import Foundation

/// Accessibility (TCC) checks.
public enum Permissions {
    /// `AXIsProcessTrusted()`.
    public static func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    /// `AXIsProcessTrustedWithOptions` with the prompt option set.
    public static func requestAccessibility() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
