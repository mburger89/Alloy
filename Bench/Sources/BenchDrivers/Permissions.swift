import ApplicationServices
import CoreGraphics

public enum Permissions {
    /// Missing permissions for the terminal running the harness, each with where to grant it.
    /// Uses the Preflight/Trusted checks only; never prompts.
    public static func missing() -> [String] {
        var out: [String] = []
        if !CGPreflightScreenCaptureAccess() {
            out.append("Screen Recording (System Settings > Privacy & Security > Screen & System Audio Recording)")
        }
        if !AXIsProcessTrusted() {
            out.append("Accessibility (System Settings > Privacy & Security > Accessibility)")
        }
        return out
    }
}
