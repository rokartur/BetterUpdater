//
//  UpdateWindowPresenter.swift
//  \(BetterUpdater.configuration.displayName)
//
//  Manages a Sparkle-like update window (NSPanel) that hosts UpdateWindowView.
//  Shown automatically when a new version is detected via GitHub Releases API.
//

import AppKit
import SwiftUI
import Combine

@MainActor
public final class UpdateWindowPresenter {

    // MARK: - Singleton

    public static let shared = UpdateWindowPresenter()

    // MARK: - Private Properties

    private var panel: NSPanel?
    private var updateView: UpdateWindowView?
    private var stateObserver: AnyCancellable?
    private var betaToggleObserver: AnyCancellable?

    // MARK: - Init

    private init() {
        observeUpdaterState()
    }

    // MARK: - Public

    /// Show (or bring to front) the update window.
    public func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        // Accessory apps can't own the key window — switch to regular first.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }

        panel.center()
        panel.orderFrontRegardless()

        // Force a fresh render of release notes against whatever the updater
        // most recently fetched. Combine observers ARE wired but they can
        // race a hidden-then-shown popup; this is the belt-and-suspenders
        // guarantee that `show()` always reflects the latest GitHub data.
        updateView?.forceReloadContent()

        // Activate after a run-loop tick so the policy switch is fully applied.
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Hide the update window without resetting updater state.
    public func hide() {
        panel?.orderOut(nil)
        restoreActivationPolicyIfNeeded()
    }

    /// Whether the window is currently visible.
    public var isVisible: Bool {
        panel?.isVisible ?? false
    }

    // MARK: - Private

    private func createPanel() {
        let size = NSSize(
            width: UpdateWindowView.Layout.windowWidth,
            height: UpdateWindowView.Layout.windowHeight
        )

        let panel = UpdatePanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.animationBehavior = .documentWindow
        panel.hidesOnDeactivate = false

        // Fixed size (no title bar, so content size = window size)
        panel.contentMinSize = size
        panel.contentMaxSize = size

        // Build content view hierarchy
        guard let contentView = panel.contentView else { return }
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 16
        contentView.layer?.cornerCurve = .continuous
        contentView.layer?.masksToBounds = true

        // Clear the window frame view background (prevents rectangular background on macOS 26+)
        if let frameView = contentView.superview {
            frameView.wantsLayer = true
            if frameView.layer == nil { frameView.layer = CALayer() }
            frameView.layer?.backgroundColor = NSColor.clear.cgColor
            frameView.layer?.cornerRadius = 16
            frameView.layer?.cornerCurve = .continuous
            frameView.layer?.masksToBounds = true
        }

        // Glass/vibrancy background
        let background = makeBackground(cornerRadius: 16)
        background.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            background.topAnchor.constraint(equalTo: contentView.topAnchor),
            background.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])

        let updateView = UpdateWindowView(frame: contentView.bounds)
        updateView.autoresizingMask = [.width, .height]
        contentView.addSubview(updateView)

        self.panel = panel
        self.updateView = updateView
    }

    private func makeBackground(cornerRadius: CGFloat) -> NSView {
        if let glassClass = NSClassFromString("NSGlassEffectView") as? NSView.Type {
            let glassView = glassClass.init(frame: .zero)

            if let effectView = glassView as? NSVisualEffectView {
                effectView.state = .active
            }
            if glassView.responds(to: Selector(("setCornerRadius:"))) {
                glassView.setValue(cornerRadius, forKey: "cornerRadius")
            }
            if glassView.responds(to: Selector(("set_variant:"))) {
                glassView.setValue(LiquidGlassVariant.bestSupportedVariant.rawValue, forKey: "_variant")
            }
            if glassView.responds(to: Selector(("setUsesAccentColor:"))) {
                glassView.setValue(false, forKey: "usesAccentColor")
            }
            if glassView.responds(to: Selector(("setAutomaticGrouping:"))) {
                glassView.setValue(true, forKey: "automaticGrouping")
            }
            if glassView.responds(to: Selector(("setNativeRendering:"))) {
                glassView.setValue(true, forKey: "nativeRendering")
            }
            if glassView.responds(to: Selector(("setIntegratedWithWindow:"))) {
                glassView.setValue(true, forKey: "integratedWithWindow")
            }

            glassView.wantsLayer = true
            glassView.layer?.masksToBounds = true
            return glassView
        } else {
            let effectView = NSVisualEffectView()
            effectView.material = .popover
            effectView.state = .active
            effectView.blendingMode = .behindWindow
            effectView.wantsLayer = true
            effectView.layer?.cornerRadius = cornerRadius
            effectView.layer?.cornerCurve = .continuous
            effectView.layer?.masksToBounds = true
            return effectView
        }
    }

    /// Observe updater state changes to auto-show window on .available
    /// and auto-close when updater resets to .idle after skip/remind/install.
    private func observeUpdaterState() {
        stateObserver = GitHubUpdater.shared.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .idle, .upToDate:
                    // Auto-close when updater resets
                    self.hide()
                default:
                    break
                }
            }

        // Toggling the beta channel invalidates whatever release is currently
        // on display (stable vs prerelease endpoints return different rows).
        // Close the window so the user re-runs a check instead of staring at
        // stale release notes for an offer that no longer applies.
        // `dropFirst()` skips the initial value at subscribe time so we
        // only react to genuine toggles.
        betaToggleObserver = GitHubUpdater.shared.$includePreReleases
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, self.isVisible else { return }
                // Don't yank the window out from under an in-flight download
                // or install — the user still needs progress feedback.
                switch GitHubUpdater.shared.state {
                case .downloading, .installing, .readyToInstall:
                    return
                default:
                    self.hide()
                }
            }
    }

    /// Revert to accessory activation policy only if no other visible regular windows remain.
    private func restoreActivationPolicyIfNeeded() {
        let hasOtherVisibleWindow = NSApp.windows.contains { window in
            window !== panel && window.isVisible && !(window is NSPanel)
        }
        if !hasOtherVisibleWindow {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Custom Panel

    /// NSPanel subclass that can become key (for keyboard interaction)
    /// but doesn't force the app to activate.
    private final class UpdatePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }
}
