import AppKit
import CallAudio
import SwiftUI

/// Development renderer: `CallMenu --notch-preview <directory>` draws the notch
/// surface in representative states over the desktop picture, at real screen
/// coordinates with the camera housing on top, and writes PNGs. It never creates
/// audio stores and needs no Screen Recording access (it captures only its own
/// offscreen window).
enum CallNotchPreview {
    static func runIfRequested() {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--notch-preview") else { return }
        let directory = URL(fileURLWithPath: arguments.indices.contains(index + 1) ? arguments[index + 1] : ".")
        MainActor.assumeIsolated { render(to: directory) }
    }

    private struct Scene {
        let name: String
        let expanded: Bool
        let model: CallNotchModel
        var outline = false
    }

    @MainActor private static func render(to directory: URL) {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 })
        let screenFrame = screen.map { CGRect(origin: .zero, size: $0.frame.size) } ?? CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let offsetX = screen?.frame.minX ?? 0
        let safeTop = screen?.safeAreaInsets.top ?? 32
        let left = screen?.auxiliaryTopLeftArea.map { $0.offsetBy(dx: -offsetX, dy: 0) } ?? CGRect(x: 0, y: 1085, width: 771.5, height: 32)
        let right = screen?.auxiliaryTopRightArea.map { $0.offsetBy(dx: -offsetX, dy: 0) } ?? CGRect(x: 956.5, y: 1085, width: 771.5, height: 32)
        let visible = CGRect(x: 0, y: 0, width: screenFrame.width, height: screenFrame.height - safeTop)
        let backgroundIndex = CommandLine.arguments.firstIndex(of: "--background")
        let backgroundURL = backgroundIndex.flatMap { CommandLine.arguments.indices.contains($0 + 1) ? URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) : nil }
            ?? NSWorkspace.shared.desktopImageURL(for: screen ?? NSScreen.main!)
        let wallpaper = backgroundURL.flatMap { NSImage(contentsOf: $0) }

        let scenes = sampleScenes()
        let sceneHeight: CGFloat = 330
        let content = VStack(spacing: 0) {
            ForEach(Array(scenes.enumerated()), id: \.offset) { _, scene in
                SceneView(scene: scene, screenFrame: screenFrame, wallpaper: wallpaper) { measured in
                    CallNotchLayout.make(screenFrame: screenFrame, visibleFrame: visible, safeTop: safeTop,
                        auxiliaryLeft: left, auxiliaryRight: right, expanded: scene.expanded,
                        showsEars: scene.model.hasActivity, preferredExpandedHeight: measured)
                }
                    .frame(width: screenFrame.width, height: sceneHeight, alignment: .top)
                    .clipped()
            }
        }
        let size = CGSize(width: screenFrame.width, height: sceneHeight * CGFloat(scenes.count))
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -30000, y: -30000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = true
        window.backgroundColor = .black
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = NSHostingView(rootView: content)
        window.orderFrontRegardless()

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
            guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage") else {
                fputs("Window capture is unavailable\n", stderr); exit(1)
            }
            let capture = unsafeBitCast(symbol, to: Capture.self)
            guard let image = capture(.null, 8, UInt32(window.windowNumber), 1 | 8)?.takeRetainedValue() else {
                fputs("Window capture failed\n", stderr); exit(1)
            }
            let scale = CGFloat(image.width) / size.width
            let cropWidth: CGFloat = 860
            for (index, scene) in scenes.enumerated() {
                let visibleHeight: CGFloat = scene.expanded ? sceneHeight : 72
                let width = scene.expanded ? cropWidth : 460
                let crop = CGRect(x: (screenFrame.midX - width / 2) * scale, y: CGFloat(index) * sceneHeight * scale,
                                  width: width * scale, height: visibleHeight * scale).integral
                guard let part = image.cropping(to: crop),
                      let data = NSBitmapImageRep(cgImage: part).representation(using: .png, properties: [:]) else { continue }
                let url = directory.appendingPathComponent("notch-\(index + 1)-\(scene.name).png")
                try? data.write(to: url)
                print(url.path)
            }
            exit(0)
        }
        app.run()
    }

    private struct SceneView: View {
        let scene: Scene
        let screenFrame: CGRect
        let wallpaper: NSImage?
        let makeLayout: (CGFloat?) -> CallNotchLayout
        @State private var measured: CGFloat?

        var body: some View {
            let layout = makeLayout(measured)
            let notch = CGRect(x: screenFrame.midX - layout.notchWidth / 2, y: 0,
                               width: layout.notchWidth, height: layout.notchHeight)
            ZStack(alignment: .topLeading) {
                if let wallpaper {
                    Image(nsImage: wallpaper).resizable().aspectRatio(contentMode: .fill)
                        .frame(width: screenFrame.width, height: screenFrame.height, alignment: .top)
                } else {
                    LinearGradient(colors: [.indigo, .purple, .orange], startPoint: .top, endPoint: .bottom)
                }
                menuBar(layout)
                CallNotchSurface(model: scene.model,
                    chrome: CallNotchChrome(expanded: scene.expanded, attached: layout.isHardwareNotch,
                                            showsEars: scene.model.hasActivity, notchWidth: layout.notchWidth, notchHeight: layout.notchHeight,
                                            expandedWidth: min(CallNotchLayout.expandedWidth, screenFrame.width),
                                            expandedHeight: scene.expanded ? layout.frame.height : nil),
                    actions: { var actions = CallNotchActions.inert
                        actions.preferredExpandedHeight = { height in
                            DispatchQueue.main.async { if abs((measured ?? 0) - height) > 1 { measured = height } }
                        }
                        return actions }())
                    .frame(width: layout.frame.width, height: layout.frame.height)
                    .offset(x: layout.frame.minX, y: screenFrame.maxY - layout.frame.maxY)
                // The physical housing sits above every window.
                HousingShape()
                    .fill(scene.outline ? Color.red.opacity(0.35) : .black)
                    .overlay(HousingShape().stroke(scene.outline ? Color.red : .clear, lineWidth: 0.5))
                    .frame(width: notch.width, height: notch.height)
                    .offset(x: notch.minX)
            }
            .frame(width: screenFrame.width, height: screenFrame.height, alignment: .topLeading)
        }

        private func menuBar(_ layout: CallNotchLayout) -> some View {
            HStack(spacing: 18) {
                Image(systemName: "apple.logo").font(.system(size: 14, weight: .semibold))
                Text("Finder").fontWeight(.bold)
                Text("File"); Text("Edit"); Text("View"); Text("Go")
                Spacer()
                Image(systemName: "wifi"); Image(systemName: "battery.75percent")
                Text("Tue Sep 22  9:41 AM")
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .frame(width: screenFrame.width, height: layout.notchHeight > 0 ? layout.notchHeight : 24)
        }
    }

    /// An approximation of the built-in camera housing, used only for alignment previews.
    private struct HousingShape: Shape {
        func path(in rect: CGRect) -> Path {
            // The shell draws from the origin; shift it so the fillets flare outside `rect`.
            NotchShell(attached: true, expanded: false)
                .path(in: CGRect(origin: .zero, size: CGSize(width: rect.width + 12, height: rect.height)))
                .offsetBy(dx: rect.minX - 6, dy: rect.minY)
        }
    }

    private static func sampleScenes() -> [Scene] {
        let task = "Call Dr. Patel’s office and move Thursday’s appointment to next week"
        let base = CallNotchModel(title: "Phone Assistant", hasTask: false, status: "Waiting for Codex", tone: .idle,
            busy: false, active: false, muted: false, mode: .assistant,
            microphoneToCaller: false, microphoneToAgent: false, listeningToCaller: false,
            level: 0, notice: nil, hasOrigin: false, primary: .ready)
        var live = base
        live.title = task; live.hasTask = true; live.status = "Audio connected"; live.tone = .live
        live.active = true; live.mode = .listen; live.listeningToCaller = true; live.level = 0.65
        live.hasOrigin = true; live.primary = .disconnect
        var question = live
        question.tone = .attention; question.status = "Your input is needed"; question.level = 0.2
        question.notice = .question("They can do Tuesday at 10:30 or Wednesday at 2. Which works?", deliveryFailed: false)
        var failure = base
        failure.title = "No call in progress"; failure.status = "Audio needs attention"; failure.tone = .attention
        failure.notice = .error("Phone has not activated Phone Assistant as its microphone. Disconnect and reconnect to retry automatic selection.")
        var outline = base
        outline.tone = .idle
        return [
            Scene(name: "compact-idle", expanded: false, model: base),
            Scene(name: "compact-idle-alignment", expanded: false, model: base, outline: true),
            Scene(name: "compact-alignment", expanded: false, model: live, outline: true),
            Scene(name: "compact-live", expanded: false, model: live),
            Scene(name: "expanded-idle", expanded: true, model: base),
            Scene(name: "expanded-live", expanded: true, model: live),
            Scene(name: "expanded-question", expanded: true, model: question),
            Scene(name: "compact-error", expanded: false, model: failure),
            Scene(name: "expanded-error", expanded: true, model: failure)
        ]
    }
}

extension CallNotchActions {
    static let inert = CallNotchActions(expand: {}, collapse: {}, hovered: { _ in }, openHistory: {},
        openSettings: {}, openCodex: {}, hide: {}, choose: { _ in }, toggleMute: {}, stop: {}, connect: {},
        openSetup: { _ in }, preferredExpandedHeight: { _ in })
}
