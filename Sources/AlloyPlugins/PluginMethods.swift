import AlloyCore
import Foundation

/// What a plugin to Alloy request needs granted before it reaches Alloy's services.
public enum PluginMethods {
    public static func requiredPermission(_ method: String) -> PluginPermission? {
        switch method {
        case "document/text", "project/read": .projectRead
        case "project/write": .projectWrite
        default: nil
        }
    }
}
