import SwiftUI

struct RootViewModifier: ViewModifier {
    @Environment(\.updateSize) private var updateSize

    @State private var scenePhase: ScenePhase = .background

    let windowTitle: String

    func body(content: Content) -> some View {
        content
            .environment(\.scenePhase, scenePhase)
            .edgesIgnoringSafeArea(.all)
            .background(
                GeometryReader { geometry in
                    Color.clear
                        .onAppear {
                            updateSize?(size: geometry.size)
                        }
                        .onChange(of: geometry.size) { _ in
                            updateSize?(size: geometry.size)
                        }
                }
            )
            .fixedSize()
            .frame(
                minWidth: 0,
                maxWidth: .infinity,
                minHeight: 0,
                maxHeight: .infinity,
                alignment: .top
            )
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
                guard
                    let window = notification.object as? NSWindow,
                    window.title == windowTitle,
                    scenePhase != .active
                else {
                    return
                }
                scenePhase = .active
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { notification in
                guard
                    let window = notification.object as? NSWindow,
                    window.title == windowTitle,
                    scenePhase != .background
                else {
                    return
                }
                scenePhase = .background
            }
    }
}
