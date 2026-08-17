import Foundation

public enum FarframeFeature: String, Equatable, Sendable {
    case remoteDesktop
    case settings
}

public enum FarframeError: Error, Equatable, Sendable {
    case invalidConfiguration
    case featureUnavailable(FarframeFeature)
}

extension FarframeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            return "The application configuration is invalid."
        case let .featureUnavailable(feature):
            return "\(feature.rawValue) is not available."
        }
    }
}
