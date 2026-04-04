import SwiftUI

struct UpdateSizeAction {
    typealias Action = (_ size: CGSize) -> Void

    let action: Action

    func callAsFunction(size: CGSize) {
        action(size)
    }
}

private struct UpdateSizeKey: EnvironmentKey {
    static var defaultValue: UpdateSizeAction?
}

extension EnvironmentValues {
    var updateSize: UpdateSizeAction? {
        get { self[UpdateSizeKey.self] }
        set { self[UpdateSizeKey.self] = newValue }
    }
}

extension View {
    func onSizeUpdate(_ action: @escaping (_ size: CGSize) -> Void) -> some View {
        environment(\.updateSize, UpdateSizeAction(action: action))
    }
}
