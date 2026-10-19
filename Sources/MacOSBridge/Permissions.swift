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
        checkAccessibility(prompt: true)
    }

    /// `AXIsProcessTrustedWithOptions`. When `prompt` is true and the process
    /// is not trusted, macOS shows the Accessibility prompt.
    public static func checkAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }
}
