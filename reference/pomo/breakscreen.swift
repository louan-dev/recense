import Cocoa

let facts = [
    "Octopuses have three hearts and blue blood.",
    "A group of flamingos is called a flamboyance.",
    "Sea otters wrap themselves in kelp so they don't drift away while they sleep.",
    "Wombats produce cube-shaped droppings.",
    "Crows can recognize individual human faces.",
    "Elephants can recognize themselves in a mirror."
]

class Overlay: NSWindow {
    override var canBecomeKey: Bool { true }
    override func keyDown(with event: NSEvent) {}
}

final class Controller: NSObject {
    let window: Overlay

    init(title: String) {
        let frame = NSScreen.main!.frame
        window = Overlay(contentRect: frame, styleMask: [.borderless],
                         backing: .buffered, defer: false)
        super.init()
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.alphaValue = 0

        let blur = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        window.contentView = blur

        let icon = NSImageView(image: NSImage(systemSymbolName: "timer",
                                              accessibilityDescription: nil)!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 40, weight: .light)
        icon.contentTintColor = .systemGreen

        let heading = NSTextField(labelWithString: title)
        heading.font = .systemFont(ofSize: 34, weight: .bold)
        heading.textColor = .white

        let sub = NSTextField(labelWithAttributedString: NSAttributedString(
            string: "WILDLIFE FACT-FILE",
            attributes: [.kern: 2.0,
                         .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                         .foregroundColor: NSColor.white.withAlphaComponent(0.7)]))

        let msg = NSTextField(wrappingLabelWithString: facts.randomElement()!)
        msg.alignment = .center
        msg.font = .systemFont(ofSize: 16, weight: .medium)
        msg.textColor = .white
        msg.preferredMaxLayoutWidth = 380
        msg.widthAnchor.constraint(lessThanOrEqualToConstant: 380).isActive = true

        let button = NSButton(title: "Nice", target: self, action: #selector(dismiss))
        button.bezelStyle = .rounded

        let stack = NSStackView(views: [icon, heading, sub, msg, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor)
        ])
    }

    func show() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 1
        }
    }

    @objc func dismiss() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.6
            window.animator().alphaValue = 0
        }, completionHandler: { NSApp.terminate(nil) })
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let title = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Timer Complete"
let controller = Controller(title: title)
controller.show()
app.run()
