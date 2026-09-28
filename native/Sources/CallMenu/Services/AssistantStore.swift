import CallPreferences
import Combine
import Foundation

@MainActor final class AssistantStore: ObservableObject {
    @Published var preferences: AssistantPreferences {
        didSet { preferences.save(to: defaults) }
    }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = AssistantPreferences.load(from: defaults)
    }
}
