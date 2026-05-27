//
//  UpdateWindowView.swift
//  \(BetterUpdater.configuration.displayName)
//
//  Sparkle-like update window UI (pure AppKit).
//  Shows release notes, version info, and action buttons.
//  Supports macOS 26 Tahoe Liquid Glass effects with graceful fallback.
//

import AppKit
import SwiftUI
import Combine

final class UpdateWindowView: NSView {

    // MARK: - Layout Constants

    enum Layout {
        static let windowWidth: CGFloat = 580
        static let windowHeight: CGFloat = 540
        static let horizontalPadding: CGFloat = 28
        static let iconSize: CGFloat = 72
        static let progressHeight: CGFloat = 6
        static let progressCornerRadius: CGFloat = 3
        static let buttonSpacing: CGFloat = 12
        static let topPadding: CGFloat = 24
        static let headerBottomPadding: CGFloat = 20
        static let actionBarTopPadding: CGFloat = 18
        static let actionBarBottomPadding: CGFloat = 18
    }

    // MARK: - Subviews

    // Header
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    // Header extras — banner + beta caption stack so hidden rows auto-collapse.
    private let headerExtrasStack = NSStackView()
    private let installFailureBannerContainer = NSView()
    private let installFailureBannerIcon = NSImageView()
    private let installFailureBanner = NSTextField(labelWithString: "")
    private let betaCaptionContainer = NSView()
    private let betaCaptionLabel = NSTextField(labelWithString: "")
    private let disableBetasButton = NSButton(title: String(localized: "Turn off betas", table: "Updater", bundle: .module), target: nil, action: nil)

    // Separators
    private let topSeparator = NSBox()
    private let bottomSeparator = NSBox()

    // Release Notes
    private let releaseNotesLabel = NSTextField(labelWithString: "Release Notes")
    private let dateLabel = NSTextField(labelWithString: "")
    private let releaseNotesContainer = NSView()
    private var releaseNotesScrollView: NSScrollView?
    private var releaseNotesMarkdownView: MarkdownNSView?
    private var releaseNotesEmptyView: NSView?

    // Action Bar
    private let actionBarContainer = NSView()

    // Available state
    private let skipButton = NSButton(title: String(localized: "Skip This Version", table: "Updater", bundle: .module), target: nil, action: nil)
    private let remindButton = NSButton(title: String(localized: "Remind me in 3 days", table: "Updater", bundle: .module), target: nil, action: nil)
    private let installButton = NSButton(title: String(localized: "Install Update", table: "Updater", bundle: .module), target: nil, action: nil)

    // Downloading state
    private let progressTrack = CALayer()
    private let progressFill = CALayer()
    private let progressContainer = NSView()
    private let downloadLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: String(localized: "Cancel", table: "Updater", bundle: .module), target: nil, action: nil)

    // Ready to install state
    private let laterButton = NSButton(title: String(localized: "Later", table: "Updater", bundle: .module), target: nil, action: nil)
    private let installRestartButton = NSButton(title: String(localized: "Install & Restart", table: "Updater", bundle: .module), target: nil, action: nil)

    // Installing state
    private let installProgressContainer = NSView()
    private let installProgressTrack = CALayer()
    private let installProgressFill = CALayer()
    private let installStepLabel = NSTextField(labelWithString: "")
    private let installPercentLabel = NSTextField(labelWithString: "")

    // Error state
    private let closeButton = NSButton(title: String(localized: "Close", table: "Updater", bundle: .module), target: nil, action: nil)
    private let retryButton = NSButton(title: String(localized: "Try Again", table: "Updater", bundle: .module), target: nil, action: nil)

    // MARK: - State

    private var cancellables = Set<AnyCancellable>()
    private let updater = GitHubUpdater.shared

    // Track action bar height constraint for different states
    private var actionBarHeightConstraint: NSLayoutConstraint?

    // MARK: - Init

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupViews()
        setupConstraints()
        observeState()
    }

    required init?(coder: NSCoder) {
        fatalCoderNotImplemented()
    }

    // MARK: - Setup

    private func setupViews() {
        wantsLayer = true

        // Header icon
        iconView.image = Self.appIcon()
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityLabel(String(localized: "\(BetterUpdater.configuration.displayName) app icon", table: "Updater", bundle: .module))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        // Title — large, bold. Visual hierarchy: this is the headline.
        configureLabel(titleLabel, text: "",
                        fontSize: 18, weight: .bold, color: .labelColor)
        addSubview(titleLabel)

        // Version — medium weight, shows transition (e.g. "26.6.1 → 26.6.2").
        configureLabel(versionLabel, text: "", fontSize: 13, weight: .regular, color: .secondaryLabelColor)
        addSubview(versionLabel)

        // Subtitle — secondary CTA, smaller and dimmer.
        configureLabel(subtitleLabel, text: String(localized: "Would you like to download it now?", table: "Updater", bundle: .module),
                        fontSize: 12, weight: .regular, color: .tertiaryLabelColor)
        addSubview(subtitleLabel)

        // Install-failure banner + beta caption stack (auto-collapses on hidden rows).
        setupHeaderExtras()

        // Separators
        configureSeparator(topSeparator)
        addSubview(topSeparator)

        configureSeparator(bottomSeparator)
        addSubview(bottomSeparator)

        // Release notes container (SwiftUI scroll content)
        releaseNotesContainer.translatesAutoresizingMaskIntoConstraints = false
        releaseNotesContainer.wantsLayer = true
        addSubview(releaseNotesContainer)

        // Release notes header labels (inside container)
        configureLabel(releaseNotesLabel,
                       text: String(localized: "RELEASE NOTES", table: "Updater", bundle: .module),
                       fontSize: 10, weight: .semibold, color: .tertiaryLabelColor)
        releaseNotesLabel.maximumNumberOfLines = 1
        // Letter-spaced caps for that "section header" feel.
        let notesTitleAttr = NSMutableAttributedString(string: releaseNotesLabel.stringValue)
        notesTitleAttr.addAttributes([
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: 1.2
        ], range: NSRange(location: 0, length: notesTitleAttr.length))
        releaseNotesLabel.attributedStringValue = notesTitleAttr
        releaseNotesContainer.addSubview(releaseNotesLabel)

        configureLabel(dateLabel, text: "", fontSize: 10, weight: .regular, color: .tertiaryLabelColor)
        dateLabel.alignment = .right
        dateLabel.maximumNumberOfLines = 1
        releaseNotesContainer.addSubview(dateLabel)

        setupReleaseNotesBackground()

        // Action bar
        actionBarContainer.translatesAutoresizingMaskIntoConstraints = false
        actionBarContainer.wantsLayer = true
        setupActionBarBackground()
        addSubview(actionBarContainer)

        setupActionButtons()
    }

    private func setupHeaderExtras() {
        headerExtrasStack.orientation = .vertical
        headerExtrasStack.alignment = .leading
        headerExtrasStack.spacing = 6
        headerExtrasStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(headerExtrasStack)

        // Failure banner — subtle orange tint with warning icon. Smaller
        // visual weight than the yellow brick that dominated v1.
        installFailureBannerContainer.translatesAutoresizingMaskIntoConstraints = false
        installFailureBannerContainer.wantsLayer = true
        installFailureBannerContainer.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(0.10).cgColor
        installFailureBannerContainer.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.30).cgColor
        installFailureBannerContainer.layer?.borderWidth = 0.5
        installFailureBannerContainer.layer?.cornerRadius = 8
        installFailureBannerContainer.isHidden = true

        let iconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        installFailureBannerIcon.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                                  accessibilityDescription: nil)?
            .withSymbolConfiguration(iconConfig)
        installFailureBannerIcon.contentTintColor = .systemOrange
        installFailureBannerIcon.translatesAutoresizingMaskIntoConstraints = false
        installFailureBannerIcon.imageScaling = .scaleNone
        installFailureBannerContainer.addSubview(installFailureBannerIcon)

        installFailureBanner.font = .systemFont(ofSize: 12, weight: .regular)
        installFailureBanner.textColor = .labelColor
        installFailureBanner.maximumNumberOfLines = 3
        installFailureBanner.lineBreakMode = .byWordWrapping
        installFailureBanner.translatesAutoresizingMaskIntoConstraints = false
        installFailureBanner.drawsBackground = false
        installFailureBanner.isBezeled = false
        installFailureBanner.isEditable = false
        installFailureBanner.preferredMaxLayoutWidth = UpdateWindowView.Layout.windowWidth - UpdateWindowView.Layout.horizontalPadding * 2 - 40
        installFailureBannerContainer.addSubview(installFailureBanner)
        NSLayoutConstraint.activate([
            installFailureBannerIcon.leadingAnchor.constraint(equalTo: installFailureBannerContainer.leadingAnchor, constant: 12),
            installFailureBannerIcon.topAnchor.constraint(equalTo: installFailureBannerContainer.topAnchor, constant: 10),
            installFailureBannerIcon.widthAnchor.constraint(equalToConstant: 16),
            installFailureBannerIcon.heightAnchor.constraint(equalToConstant: 16),

            installFailureBanner.leadingAnchor.constraint(equalTo: installFailureBannerIcon.trailingAnchor, constant: 10),
            installFailureBanner.trailingAnchor.constraint(equalTo: installFailureBannerContainer.trailingAnchor, constant: -12),
            installFailureBanner.topAnchor.constraint(equalTo: installFailureBannerContainer.topAnchor, constant: 8),
            installFailureBanner.bottomAnchor.constraint(equalTo: installFailureBannerContainer.bottomAnchor, constant: -8),
        ])
        headerExtrasStack.addArrangedSubview(installFailureBannerContainer)

        // Beta caption row: "Showing pre-releases. [Turn off betas]"
        betaCaptionContainer.translatesAutoresizingMaskIntoConstraints = false
        betaCaptionContainer.isHidden = true

        configureLabel(betaCaptionLabel,
                       text: String(localized: "Showing pre-releases.", table: "Updater", bundle: .module),
                       fontSize: 11, weight: .regular, color: .secondaryLabelColor)
        betaCaptionLabel.maximumNumberOfLines = 1
        betaCaptionContainer.addSubview(betaCaptionLabel)

        disableBetasButton.translatesAutoresizingMaskIntoConstraints = false
        disableBetasButton.isBordered = false
        disableBetasButton.font = .systemFont(ofSize: 11, weight: .medium)
        disableBetasButton.contentTintColor = .systemBlue
        disableBetasButton.target = self
        disableBetasButton.action = #selector(disableBetasTapped)
        disableBetasButton.toolTip = String(localized: "Disable pre-release updates and dismiss this offer", table: "Updater", bundle: .module)
        betaCaptionContainer.addSubview(disableBetasButton)

        NSLayoutConstraint.activate([
            betaCaptionLabel.leadingAnchor.constraint(equalTo: betaCaptionContainer.leadingAnchor),
            betaCaptionLabel.centerYAnchor.constraint(equalTo: betaCaptionContainer.centerYAnchor),
            betaCaptionLabel.topAnchor.constraint(equalTo: betaCaptionContainer.topAnchor),
            betaCaptionLabel.bottomAnchor.constraint(equalTo: betaCaptionContainer.bottomAnchor),
            disableBetasButton.leadingAnchor.constraint(equalTo: betaCaptionLabel.trailingAnchor, constant: 6),
            disableBetasButton.centerYAnchor.constraint(equalTo: betaCaptionContainer.centerYAnchor),
            disableBetasButton.trailingAnchor.constraint(lessThanOrEqualTo: betaCaptionContainer.trailingAnchor),
        ])
        headerExtrasStack.addArrangedSubview(betaCaptionContainer)
    }

    private func setupReleaseNotesBackground() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if #available(macOS 26, *) {
            // On glass, use very subtle tint — the glass itself provides depth
            releaseNotesContainer.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(isDark ? 0.04 : 0.02).cgColor
        } else {
            releaseNotesContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(isDark ? 0.15 : 0.03).cgColor
        }
    }

    private func setupActionBarBackground() {
        // No background on action bar — the glass behind provides enough visual separation
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        setupReleaseNotesBackground()
        setupActionBarBackground()
    }

    private func configureSeparator(_ box: NSBox) {
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *) {
            box.alphaValue = 0.3
        }
    }

    private func configureLabel(_ label: NSTextField, text: String, fontSize: CGFloat, weight: NSFont.Weight, color: NSColor) {
        label.stringValue = text
        label.font = .systemFont(ofSize: fontSize, weight: weight)
        label.textColor = color
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    }

    private func setupActionButtons() {
        // Skip button — plain ghost text, low visual weight on the left.
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        skipButton.isBordered = false
        skipButton.font = .systemFont(ofSize: 12, weight: .regular)
        skipButton.contentTintColor = .tertiaryLabelColor
        skipButton.target = self
        skipButton.action = #selector(skipTapped)
        skipButton.toolTip = String(localized: "Don't remind me about this version", table: "Updater", bundle: .module)
        actionBarContainer.addSubview(skipButton)

        // Remind button — secondary push, escape-bound.
        remindButton.translatesAutoresizingMaskIntoConstraints = false
        remindButton.bezelStyle = .push
        remindButton.controlSize = .large
        remindButton.target = self
        remindButton.action = #selector(remindTapped)
        remindButton.keyEquivalent = "\u{1b}" // Escape
        actionBarContainer.addSubview(remindButton)

        // Install button — primary CTA. Symbol image leading + bold title
        // for stronger affordance than default push.
        installButton.translatesAutoresizingMaskIntoConstraints = false
        installButton.bezelStyle = .push
        installButton.controlSize = .large
        installButton.hasDestructiveAction = false
        installButton.target = self
        installButton.action = #selector(installTapped)
        installButton.keyEquivalent = "\r" // Return
        let installIconConfig = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        installButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(installIconConfig)
        installButton.imagePosition = .imageLeading
        installButton.imageScaling = .scaleProportionallyDown
        setProminent(installButton)
        actionBarContainer.addSubview(installButton)

        // Download progress
        progressContainer.translatesAutoresizingMaskIntoConstraints = false
        progressContainer.wantsLayer = true
        progressContainer.layer?.cornerRadius = Layout.progressCornerRadius
        progressContainer.layer?.masksToBounds = true
        actionBarContainer.addSubview(progressContainer)

        progressTrack.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        progressContainer.layer?.addSublayer(progressTrack)

        progressFill.backgroundColor = NSColor.controlAccentColor.cgColor
        progressFill.cornerRadius = Layout.progressCornerRadius
        progressContainer.layer?.addSublayer(progressFill)

        configureLabel(downloadLabel, text: "", fontSize: 12, weight: .regular, color: .secondaryLabelColor)
        actionBarContainer.addSubview(downloadLabel)

        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isBordered = false
        cancelButton.font = .systemFont(ofSize: 12)
        cancelButton.contentTintColor = .secondaryLabelColor
        cancelButton.target = self
        cancelButton.action = #selector(cancelTapped)
        actionBarContainer.addSubview(cancelButton)

        // Ready to install
        laterButton.translatesAutoresizingMaskIntoConstraints = false
        laterButton.bezelStyle = .push
        laterButton.controlSize = .large
        laterButton.target = self
        laterButton.action = #selector(remindTapped)
        laterButton.keyEquivalent = "\u{1b}"
        actionBarContainer.addSubview(laterButton)

        installRestartButton.translatesAutoresizingMaskIntoConstraints = false
        installRestartButton.bezelStyle = .push
        installRestartButton.controlSize = .large
        installRestartButton.target = self
        installRestartButton.action = #selector(installRestartTapped)
        installRestartButton.keyEquivalent = "\r"
        installRestartButton.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
        installRestartButton.imagePosition = .imageLeading
        setProminent(installRestartButton)
        actionBarContainer.addSubview(installRestartButton)

        // Installing progress
        installProgressContainer.translatesAutoresizingMaskIntoConstraints = false
        installProgressContainer.wantsLayer = true
        installProgressContainer.layer?.cornerRadius = Layout.progressCornerRadius
        installProgressContainer.layer?.masksToBounds = true
        actionBarContainer.addSubview(installProgressContainer)

        installProgressTrack.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
        installProgressContainer.layer?.addSublayer(installProgressTrack)

        installProgressFill.backgroundColor = NSColor.systemOrange.cgColor
        installProgressFill.cornerRadius = Layout.progressCornerRadius
        installProgressContainer.layer?.addSublayer(installProgressFill)

        configureLabel(installStepLabel, text: "", fontSize: 12, weight: .regular, color: .secondaryLabelColor)
        installStepLabel.lineBreakMode = .byTruncatingTail
        installStepLabel.maximumNumberOfLines = 1
        actionBarContainer.addSubview(installStepLabel)

        configureLabel(installPercentLabel, text: "", fontSize: 12, weight: .medium, color: .systemOrange)
        installPercentLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        installPercentLabel.alignment = .right
        installPercentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        actionBarContainer.addSubview(installPercentLabel)

        // Error state
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.bezelStyle = .push
        closeButton.controlSize = .large
        closeButton.target = self
        closeButton.action = #selector(closeTapped)
        closeButton.keyEquivalent = "\u{1b}"
        actionBarContainer.addSubview(closeButton)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.bezelStyle = .push
        retryButton.controlSize = .large
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.keyEquivalent = "\r"
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.imagePosition = .imageLeading
        setProminent(retryButton)
        actionBarContainer.addSubview(retryButton)

        // Initially hide everything, updateUI will show the right ones
        hideAllActionViews()
    }

    private func setProminent(_ button: NSButton) {
        if #available(macOS 14, *) {
            button.bezelColor = .controlAccentColor
        }
    }

    // MARK: - Constraints

    private func setupConstraints() {
        let hp = Layout.horizontalPadding

        // Header icon
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hp),
            iconView.topAnchor.constraint(equalTo: topAnchor, constant: Layout.topPadding),
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize),
        ])

        // Title
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -hp),
            titleLabel.topAnchor.constraint(equalTo: iconView.topAnchor, constant: 2),
        ])

        // Version
        NSLayoutConstraint.activate([
            versionLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -hp),
            versionLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
        ])

        // Subtitle
        NSLayoutConstraint.activate([
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -hp),
            subtitleLabel.topAnchor.constraint(equalTo: versionLabel.bottomAnchor, constant: 6),
        ])

        // Header extras stack (banner + beta caption) — auto-collapses to 0
        // height when both rows are hidden, so layout is preserved for the
        // common "no extras" case.
        NSLayoutConstraint.activate([
            headerExtrasStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: hp),
            headerExtrasStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -hp),
            headerExtrasStack.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 8),
        ])

        // Top separator — sits below header extras (or below subtitle/icon if stack collapsed).
        NSLayoutConstraint.activate([
            topSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            topSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            topSeparator.topAnchor.constraint(equalTo: headerExtrasStack.bottomAnchor, constant: Layout.headerBottomPadding),
        ])
        // Also anchor to icon bottom so header height works for both
        let iconBottomConstraint = topSeparator.topAnchor.constraint(greaterThanOrEqualTo: iconView.bottomAnchor, constant: Layout.headerBottomPadding)
        iconBottomConstraint.isActive = true

        // Release notes container (directly after separator)
        NSLayoutConstraint.activate([
            releaseNotesContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            releaseNotesContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            releaseNotesContainer.topAnchor.constraint(equalTo: topSeparator.bottomAnchor),
        ])

        // Release notes header labels (inside container)
        NSLayoutConstraint.activate([
            releaseNotesLabel.leadingAnchor.constraint(equalTo: releaseNotesContainer.leadingAnchor, constant: hp),
            releaseNotesLabel.topAnchor.constraint(equalTo: releaseNotesContainer.topAnchor, constant: 12),

            dateLabel.trailingAnchor.constraint(equalTo: releaseNotesContainer.trailingAnchor, constant: -hp),
            dateLabel.centerYAnchor.constraint(equalTo: releaseNotesLabel.centerYAnchor),
            dateLabel.leadingAnchor.constraint(greaterThanOrEqualTo: releaseNotesLabel.trailingAnchor, constant: 8),
        ])

        // Release notes hosting view will be added dynamically in updateReleaseNotes

        // Bottom separator
        NSLayoutConstraint.activate([
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.topAnchor.constraint(equalTo: releaseNotesContainer.bottomAnchor),
        ])

        // Action bar
        let actionBarHeight = Layout.actionBarTopPadding + Layout.actionBarBottomPadding + 32 // button height ~32
        actionBarHeightConstraint = actionBarContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: actionBarHeight)
        NSLayoutConstraint.activate([
            actionBarContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            actionBarContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionBarContainer.topAnchor.constraint(equalTo: bottomSeparator.bottomAnchor),
            actionBarContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            actionBarHeightConstraint!,
        ])

        // Action bar button constraints (available state)
        setupAvailableConstraints()
        setupDownloadingConstraints()
        setupReadyToInstallConstraints()
        setupInstallingConstraints()
        setupErrorConstraints()
    }

    // MARK: - Action Bar Layout Per State

    private func setupAvailableConstraints() {
        NSLayoutConstraint.activate([
            skipButton.leadingAnchor.constraint(equalTo: actionBarContainer.leadingAnchor, constant: Layout.horizontalPadding),
            skipButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),

            installButton.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            installButton.topAnchor.constraint(equalTo: actionBarContainer.topAnchor, constant: Layout.actionBarTopPadding),
            installButton.bottomAnchor.constraint(lessThanOrEqualTo: actionBarContainer.bottomAnchor, constant: -Layout.actionBarBottomPadding),

            remindButton.trailingAnchor.constraint(equalTo: installButton.leadingAnchor, constant: -Layout.buttonSpacing),
            remindButton.centerYAnchor.constraint(equalTo: installButton.centerYAnchor),
        ])
    }

    private func setupDownloadingConstraints() {
        NSLayoutConstraint.activate([
            progressContainer.leadingAnchor.constraint(equalTo: actionBarContainer.leadingAnchor, constant: Layout.horizontalPadding),
            progressContainer.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            progressContainer.topAnchor.constraint(equalTo: actionBarContainer.topAnchor, constant: Layout.actionBarTopPadding),
            progressContainer.heightAnchor.constraint(equalToConstant: Layout.progressHeight),

            downloadLabel.leadingAnchor.constraint(equalTo: actionBarContainer.leadingAnchor, constant: Layout.horizontalPadding),
            downloadLabel.topAnchor.constraint(equalTo: progressContainer.bottomAnchor, constant: 10),

            cancelButton.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            cancelButton.centerYAnchor.constraint(equalTo: downloadLabel.centerYAnchor),
        ])
    }

    private func setupReadyToInstallConstraints() {
        NSLayoutConstraint.activate([
            installRestartButton.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            installRestartButton.topAnchor.constraint(equalTo: actionBarContainer.topAnchor, constant: Layout.actionBarTopPadding),
            installRestartButton.bottomAnchor.constraint(lessThanOrEqualTo: actionBarContainer.bottomAnchor, constant: -Layout.actionBarBottomPadding),

            laterButton.trailingAnchor.constraint(equalTo: installRestartButton.leadingAnchor, constant: -Layout.buttonSpacing),
            laterButton.centerYAnchor.constraint(equalTo: installRestartButton.centerYAnchor),
        ])
    }

    private func setupInstallingConstraints() {
        NSLayoutConstraint.activate([
            installProgressContainer.leadingAnchor.constraint(equalTo: actionBarContainer.leadingAnchor, constant: Layout.horizontalPadding),
            installProgressContainer.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            installProgressContainer.topAnchor.constraint(equalTo: actionBarContainer.topAnchor, constant: Layout.actionBarTopPadding),
            installProgressContainer.heightAnchor.constraint(equalToConstant: Layout.progressHeight),

            installStepLabel.leadingAnchor.constraint(equalTo: actionBarContainer.leadingAnchor, constant: Layout.horizontalPadding),
            installStepLabel.topAnchor.constraint(equalTo: installProgressContainer.bottomAnchor, constant: 10),
            installStepLabel.trailingAnchor.constraint(lessThanOrEqualTo: installPercentLabel.leadingAnchor, constant: -8),

            installPercentLabel.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            installPercentLabel.centerYAnchor.constraint(equalTo: installStepLabel.centerYAnchor),
        ])
    }

    private func setupErrorConstraints() {
        NSLayoutConstraint.activate([
            retryButton.trailingAnchor.constraint(equalTo: actionBarContainer.trailingAnchor, constant: -Layout.horizontalPadding),
            retryButton.topAnchor.constraint(equalTo: actionBarContainer.topAnchor, constant: Layout.actionBarTopPadding),
            retryButton.bottomAnchor.constraint(lessThanOrEqualTo: actionBarContainer.bottomAnchor, constant: -Layout.actionBarBottomPadding),

            closeButton.trailingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: -Layout.buttonSpacing),
            closeButton.centerYAnchor.constraint(equalTo: retryButton.centerYAnchor),
        ])
    }

    // MARK: - Progress Bar Layout

    override func layout() {
        super.layout()

        let trackBounds = progressContainer.bounds
        progressTrack.frame = trackBounds
        progressFill.frame = CGRect(x: 0, y: 0, width: progressFill.frame.width, height: trackBounds.height)

        let installTrackBounds = installProgressContainer.bounds
        installProgressTrack.frame = installTrackBounds
        installProgressFill.frame = CGRect(x: 0, y: 0, width: installProgressFill.frame.width, height: installTrackBounds.height)

        // Update release notes background color via layer
        setupReleaseNotesBackground()
    }

    // MARK: - State Observation

    /// Drop any cached render state and reload from the live updater. Called
    /// by `UpdateWindowPresenter.show()` so opening the popup always reflects
    /// the latest fetched release, even if observers happened to drop a
    /// state change while the window was hidden.
    func forceReloadContent() {
        lastRenderedNotesHash = nil
        updateDate(for: updater.latestRelease)
        refreshHeaderExtras()
        updateUI(for: updater.state)
    }

    private func observeState() {
        updater.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.updateUI(for: state)
            }
            .store(in: &cancellables)

        updater.$latestRelease
            .receive(on: DispatchQueue.main)
            .sink { [weak self] release in
                guard let self else { return }
                self.updateDate(for: release)
                self.refreshHeaderExtras()
                // The release body is the authoritative source for the
                // markdown panel. Re-render when the release object changes
                // so toggling beta / channels / re-checks all reflow notes
                // even without a `.available` state transition.
                self.updateReleaseNotes(for: self.updater.state)
            }
            .store(in: &cancellables)

        updater.$lastInstallAttempt
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshHeaderExtras()
            }
            .store(in: &cancellables)

        updater.$includePreReleases
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.refreshHeaderExtras()
            }
            .store(in: &cancellables)

        // Initial update
        updateUI(for: updater.state)
        updateDate(for: updater.latestRelease)
        refreshHeaderExtras()
    }

    /// Toggle visibility of the failure banner, beta caption, and the
    /// Copy Diagnostics button based on current updater state. Driven by
    /// Combine sinks above so any state change reflows the popup.
    private func refreshHeaderExtras() {
        let attempt = updater.lastInstallAttempt
        let showBanner: Bool
        switch attempt?.stage {
        case .handoffFailed, .helperExited:
            showBanner = true
        default:
            showBanner = false
        }
        if showBanner, let attempt {
            let template = String(
                localized: "The previous update to v\(attempt.version) didn't complete. Try again or download from the releases page.",
                table: "Updater"
            )
            installFailureBanner.stringValue = template
        }
        installFailureBannerContainer.isHidden = !showBanner

        let isPrereleaseOffered = updater.latestRelease?.prerelease == true
        let showBetaCaption = isPrereleaseOffered && updater.includePreReleases
        betaCaptionContainer.isHidden = !showBetaCaption
    }

    // MARK: - UI Updates

    private func updateUI(for state: UpdateState) {
        updateVersionLabel(for: state)
        updateReleaseNotes(for: state)
        updateActionBar(for: state)
    }

    private func updateTitleAndVersionLabel(for state: UpdateState) {
        if updater.isNewerBuild {
            titleLabel.stringValue = String(localized: "An updated build of \(BetterUpdater.configuration.displayName) is available!", table: "Updater", bundle: .module)
        } else {
            titleLabel.stringValue = String(localized: "A new version of \(BetterUpdater.configuration.displayName) is available!", table: "Updater", bundle: .module)
        }
    }

    private func updateVersionLabel(for state: UpdateState) {
        updateTitleAndVersionLabel(for: state)

        switch state {
        case .available(let version, _):
            if updater.isNewerBuild {
                versionLabel.attributedStringValue = arrowVersionString(
                    from: updater.currentVersion,
                    to: version,
                    suffix: String(localized: "(new build)", table: "Updater", bundle: .module)
                )
            } else {
                versionLabel.attributedStringValue = arrowVersionString(
                    from: updater.currentVersion,
                    to: version,
                    suffix: nil
                )
            }
            versionLabel.textColor = .secondaryLabelColor
        case .downloading:
            if let version = updater.latestVersion {
                versionLabel.attributedStringValue = boldVersionString(String(localized: "Downloading \(BetterUpdater.configuration.displayName) **\(version)**\u{2026}", table: "Updater", bundle: .module))
            }
            versionLabel.textColor = .secondaryLabelColor
        case .readyToInstall:
            if let version = updater.latestVersion {
                versionLabel.attributedStringValue = boldVersionString(String(localized: "\(BetterUpdater.configuration.displayName) **\(version)** is ready to install.", table: "Updater", bundle: .module))
            }
            versionLabel.textColor = .secondaryLabelColor
        case .installing(_, let step):
            versionLabel.stringValue = step
            versionLabel.textColor = .secondaryLabelColor
        case .error(let message):
            versionLabel.stringValue = message
            versionLabel.textColor = .systemRed
        default:
            if let version = updater.latestVersion {
                versionLabel.attributedStringValue = arrowVersionString(
                    from: updater.currentVersion,
                    to: version,
                    suffix: nil
                )
            }
            versionLabel.textColor = .secondaryLabelColor
        }
    }

    /// Visual: `26.6.1  →  26.6.2`  with monospaced version chips and a
    /// dimmed arrow between. Reads faster at a glance than a sentence.
    private func arrowVersionString(from current: String, to next: String, suffix: String?) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let mono = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let monoBold = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        let dim: NSColor = .tertiaryLabelColor
        let body: NSColor = .secondaryLabelColor
        let accent: NSColor = .labelColor

        result.append(NSAttributedString(string: current, attributes: [.font: mono, .foregroundColor: body]))
        result.append(NSAttributedString(string: "  →  ", attributes: [.font: mono, .foregroundColor: dim]))
        result.append(NSAttributedString(string: next, attributes: [.font: monoBold, .foregroundColor: accent]))
        if let suffix {
            result.append(NSAttributedString(string: "  \(suffix)", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: dim]))
        }
        return result
    }

    /// Parse a simple markdown-like string with **bold** into NSAttributedString
    private func boldVersionString(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let font = NSFont.systemFont(ofSize: 12)
        let boldFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let color: NSColor = .secondaryLabelColor

        let parts = text.components(separatedBy: "**")
        for (index, part) in parts.enumerated() {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: index % 2 == 1 ? boldFont : font,
                .foregroundColor: color
            ]
            result.append(NSAttributedString(string: part, attributes: attrs))
        }
        return result
    }

    /// Hash of the last successfully rendered release-notes string. Lets
    /// us treat a content change as "tear down + recreate the scrollView"
    /// instead of mutating the existing one in place — the mutate path
    /// races with NSScrollView's clipView sizing when the popup was
    /// hidden between two different releases (Skip stable → enable beta →
    /// re-check produced a blank scroll area before this).
    private var lastRenderedNotesHash: Int?

    private func updateReleaseNotes(for state: UpdateState) {
        // Always prefer the live `latestRelease.body` when available so we
        // can't drift away from what was last fetched. State-carried notes
        // are only used as a fallback if the release object is gone.
        let notes: String?
        if let release = updater.latestRelease {
            notes = release.body
        } else {
            switch state {
            case .available(_, let releaseNotes):
                notes = releaseNotes
            default:
                notes = nil
            }
        }

        let hasNotes = notes != nil && !(notes ?? "").isEmpty
        let newHash = (notes ?? "").hashValue

        if hasNotes {
            // Remove empty placeholder if present
            releaseNotesEmptyView?.removeFromSuperview()
            releaseNotesEmptyView = nil

            // If content unchanged AND view already exists, no-op.
            if let existing = releaseNotesMarkdownView, lastRenderedNotesHash == newHash {
                _ = existing  // silence unused
                return
            }

            // Content changed (or first render). Tear down stale scroll
            // view + markdown view to guarantee a clean layout pass.
            releaseNotesScrollView?.removeFromSuperview()
            releaseNotesScrollView = nil
            releaseNotesMarkdownView = nil

            do {
                let scrollView = NSScrollView()
                scrollView.translatesAutoresizingMaskIntoConstraints = false
                scrollView.hasVerticalScroller = true
                scrollView.hasHorizontalScroller = false
                scrollView.drawsBackground = false
                scrollView.automaticallyAdjustsContentInsets = false
                scrollView.contentInsets = NSEdgeInsets(top: 0, left: Layout.horizontalPadding, bottom: 12, right: Layout.horizontalPadding)

                let markdownView = MarkdownNSView()
                // Frame-based sizing — NSTextView as documentView
                markdownView.minSize = NSSize(width: 0, height: 0)
                markdownView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
                markdownView.autoresizingMask = [.width]

                scrollView.documentView = markdownView

                releaseNotesContainer.addSubview(scrollView)
                NSLayoutConstraint.activate([
                    scrollView.leadingAnchor.constraint(equalTo: releaseNotesContainer.leadingAnchor),
                    scrollView.trailingAnchor.constraint(equalTo: releaseNotesContainer.trailingAnchor),
                    scrollView.topAnchor.constraint(equalTo: releaseNotesLabel.bottomAnchor, constant: 8),
                    scrollView.bottomAnchor.constraint(equalTo: releaseNotesContainer.bottomAnchor),
                ])

                releaseNotesScrollView = scrollView
                releaseNotesMarkdownView = markdownView
                lastRenderedNotesHash = newHash

                // Force a layout pass so the scrollView's clip view has a real
                // frame BEFORE we ask MarkdownNSView to lay out text. Without
                // this, the freshly-created view sits at frame=zero until the
                // next runloop tick and a hidden popup never gets that tick
                // (this is the "blank release notes after Skip + toggle beta"
                // bug). Setting markdown last guarantees render() runs against
                // a real width.
                releaseNotesContainer.layoutSubtreeIfNeeded()
                markdownView.markdown = notes ?? ""
            }
        } else {
            lastRenderedNotesHash = nil
            // Remove markdown view if present
            releaseNotesScrollView?.removeFromSuperview()
            releaseNotesScrollView = nil
            releaseNotesMarkdownView = nil

            if releaseNotesEmptyView == nil {
                let emptyView = NSView()
                emptyView.translatesAutoresizingMaskIntoConstraints = false

                let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil) ?? NSImage())
                icon.translatesAutoresizingMaskIntoConstraints = false
                icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .regular)
                icon.contentTintColor = .tertiaryLabelColor

                let label = NSTextField(labelWithString: "No release notes available.")
                label.translatesAutoresizingMaskIntoConstraints = false
                label.font = .systemFont(ofSize: 13)
                label.textColor = .secondaryLabelColor
                label.alignment = .center

                emptyView.addSubview(icon)
                emptyView.addSubview(label)

                NSLayoutConstraint.activate([
                    icon.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
                    icon.centerYAnchor.constraint(equalTo: emptyView.centerYAnchor, constant: -16),
                    label.centerXAnchor.constraint(equalTo: emptyView.centerXAnchor),
                    label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
                ])

                releaseNotesContainer.addSubview(emptyView)
                NSLayoutConstraint.activate([
                    emptyView.leadingAnchor.constraint(equalTo: releaseNotesContainer.leadingAnchor),
                    emptyView.trailingAnchor.constraint(equalTo: releaseNotesContainer.trailingAnchor),
                    emptyView.topAnchor.constraint(equalTo: releaseNotesLabel.bottomAnchor, constant: 8),
                    emptyView.bottomAnchor.constraint(equalTo: releaseNotesContainer.bottomAnchor),
                ])

                releaseNotesEmptyView = emptyView
            }
        }
    }

    private func updateDate(for release: GitHubRelease?) {
        if let date = release?.publishedAt {
            let absolute = date.formatted(date: .abbreviated, time: .omitted)
            let relativeFmt = RelativeDateTimeFormatter()
            relativeFmt.unitsStyle = .full
            let relative = relativeFmt.localizedString(for: date, relativeTo: Date())
            dateLabel.stringValue = "\(relative) · \(absolute)"
        } else {
            dateLabel.stringValue = ""
        }
    }

    private func updateActionBar(for state: UpdateState) {
        hideAllActionViews()

        switch state {
        case .available:
            showAvailableActions()
        case .downloading(let progress):
            showDownloadingActions(progress: progress)
        case .readyToInstall:
            showReadyToInstallActions()
        case .installing(let progress, let step):
            showInstallingActions(progress: progress, step: step)
        case .error:
            showErrorActions()
        default:
            showAvailableActions()
        }
    }

    private func hideAllActionViews() {
        // Available
        skipButton.isHidden = true
        remindButton.isHidden = true
        installButton.isHidden = true
        // Downloading
        progressContainer.isHidden = true
        downloadLabel.isHidden = true
        cancelButton.isHidden = true
        // Ready
        laterButton.isHidden = true
        installRestartButton.isHidden = true
        // Installing
        installProgressContainer.isHidden = true
        installStepLabel.isHidden = true
        installPercentLabel.isHidden = true
        // Error
        closeButton.isHidden = true
        retryButton.isHidden = true
    }

    private func showAvailableActions() {
        skipButton.isHidden = false
        remindButton.isHidden = false
        installButton.isHidden = false
    }

    private func showDownloadingActions(progress: Double) {
        progressContainer.isHidden = false
        downloadLabel.isHidden = false
        cancelButton.isHidden = false

        downloadLabel.stringValue = String(localized: "Downloading — \(Int(progress * 100))%", table: "Updater", bundle: .module)

        let width = progressContainer.bounds.width * progress
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        progressFill.frame = CGRect(x: 0, y: 0, width: max(0, width), height: Layout.progressHeight)
        CATransaction.commit()
    }

    private func showReadyToInstallActions() {
        laterButton.isHidden = false
        installRestartButton.isHidden = false
    }

    private func showInstallingActions(progress: Double, step: String) {
        installProgressContainer.isHidden = false
        installStepLabel.isHidden = false
        installPercentLabel.isHidden = false

        installStepLabel.stringValue = step
        installPercentLabel.stringValue = "\(Int(progress * 100))%"

        let width = installProgressContainer.bounds.width * progress
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.3)
        installProgressFill.frame = CGRect(x: 0, y: 0, width: max(0, width), height: Layout.progressHeight)
        CATransaction.commit()
    }

    private func showErrorActions() {
        closeButton.isHidden = false
        retryButton.isHidden = false
    }

    // MARK: - Actions

    @objc private func skipTapped() {
        updater.skipCurrentUpdate()
    }

    @objc private func remindTapped() {
        updater.remindLater()
    }

    @objc private func installTapped() {
        Task { await updater.downloadAndInstall() }
    }

    @objc private func cancelTapped() {
        updater.cancelDownload()
    }

    @objc private func disableBetasTapped() {
        updater.includePreReleases = false
        // Skip the just-offered prerelease so the next stable check isn't
        // immediately re-prompted with the same beta we just dismissed.
        updater.skipCurrentUpdate()
        UpdateWindowPresenter.shared.hide()
    }

    @objc private func installRestartTapped() {
        Task { await updater.installUpdate() }
    }

    @objc private func closeTapped() {
        UpdateWindowPresenter.shared.hide()
    }

    @objc private func retryTapped() {
        Task { await updater.checkForUpdates(force: true) }
    }

    // MARK: - Helpers

    @MainActor
    static func appIcon() -> NSImage {
        let size = NSSize(width: 512, height: 512)
        if let bundleID = Bundle.main.bundleIdentifier,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = size
            return icon
        }
        if let appIcon = NSApplication.shared.applicationIconImage.copy() as? NSImage {
            appIcon.size = size
            return appIcon
        }
        return NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage(size: size)
    }
}


