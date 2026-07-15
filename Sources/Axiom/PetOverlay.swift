import AppKit
import QuartzCore

enum CodexPetAnimationState: String, CaseIterable, Sendable {
    case idle
    case runningRight = "running-right"
    case runningLeft = "running-left"
    case waving
    case jumping
    case failed
    case waiting
    case running
    case review
}

struct CodexPetFrame: Hashable, Sendable {
    let rowIndex: Int
    let columnIndex: Int
    let frameDuration: TimeInterval
}

struct CodexPetPlayback: Equatable, Sendable {
    let frames: [CodexPetFrame]
    let loopStartIndex: Int?
}

enum CodexPetAnimationContract {
    static let columnCount = 8
    static let rowCount = 11
    static let cellSize = NSSize(width: 192, height: 208)
    static let idleSlowdown = 6.0
    static let reactionRepeatCount = 3
    static let dragThreshold: CGFloat = 4
    static let dragScale: CGFloat = 0.95
    static let dragScaleDuration: TimeInterval = 0.16

    static func standardFrames(for state: CodexPetAnimationState) -> [CodexPetFrame] {
        switch state {
        case .idle:
            return [280, 110, 110, 140, 140, 320].enumerated().map { column, milliseconds in
                CodexPetFrame(rowIndex: 0, columnIndex: column, frameDuration: TimeInterval(milliseconds) / 1_000)
            }
        case .runningRight:
            return rowFrames(rowIndex: 1, count: 8, durationMilliseconds: 120, finalDurationMilliseconds: 220)
        case .runningLeft:
            return rowFrames(rowIndex: 2, count: 8, durationMilliseconds: 120, finalDurationMilliseconds: 220)
        case .waving:
            return rowFrames(rowIndex: 3, count: 4, durationMilliseconds: 140, finalDurationMilliseconds: 280)
        case .jumping:
            return rowFrames(rowIndex: 4, count: 5, durationMilliseconds: 140, finalDurationMilliseconds: 280)
        case .failed:
            return rowFrames(rowIndex: 5, count: 8, durationMilliseconds: 140, finalDurationMilliseconds: 240)
        case .waiting:
            return rowFrames(rowIndex: 6, count: 6, durationMilliseconds: 150, finalDurationMilliseconds: 260)
        case .running:
            return rowFrames(rowIndex: 7, count: 6, durationMilliseconds: 120, finalDurationMilliseconds: 220)
        case .review:
            return rowFrames(rowIndex: 8, count: 6, durationMilliseconds: 150, finalDurationMilliseconds: 280)
        }
    }

    static func playback(for state: CodexPetAnimationState, prefersReducedMotion: Bool) -> CodexPetPlayback {
        let stateFrames = standardFrames(for: state)
        if prefersReducedMotion {
            return CodexPetPlayback(frames: Array(stateFrames.prefix(1)), loopStartIndex: nil)
        }

        let idleFrames = slowedIdleFrames
        if state == .idle {
            return CodexPetPlayback(frames: idleFrames, loopStartIndex: 0)
        }

        let reactionFrames = (0..<reactionRepeatCount).flatMap { _ in stateFrames }
        return CodexPetPlayback(
            frames: reactionFrames + idleFrames,
            loopStartIndex: reactionFrames.count
        )
    }

    static func dragState(
        currentState: CodexPetAnimationState?,
        horizontalDelta: CGFloat
    ) -> CodexPetAnimationState? {
        if horizontalDelta >= dragThreshold { return .runningRight }
        if horizontalDelta <= -dragThreshold { return .runningLeft }
        return currentState
    }

    static func effectiveState(
        activityState: CodexPetAnimationState,
        isHovered: Bool,
        dragState: CodexPetAnimationState?
    ) -> CodexPetAnimationState {
        dragState ?? (isHovered ? .jumping : activityState)
    }

    static var slowedIdleFrames: [CodexPetFrame] {
        standardFrames(for: .idle).map {
            CodexPetFrame(
                rowIndex: $0.rowIndex,
                columnIndex: $0.columnIndex,
                frameDuration: $0.frameDuration * idleSlowdown
            )
        }
    }

    private static func rowFrames(
        rowIndex: Int,
        count: Int,
        durationMilliseconds: Int,
        finalDurationMilliseconds: Int
    ) -> [CodexPetFrame] {
        (0..<count).map { column in
            CodexPetFrame(
                rowIndex: rowIndex,
                columnIndex: column,
                frameDuration: TimeInterval(column == count - 1 ? finalDurationMilliseconds : durationMilliseconds) / 1_000
            )
        }
    }
}

enum CodexPetLookDirection {
    static let angleStep = 22.5
    static let directionCount = 16
    static let startingRow = 9
    static let deadzoneRadius: CGFloat = 1

    static func frame(
        mascotBounds: NSRect,
        point: NSPoint,
        spriteVersionNumber: Int
    ) -> CodexPetFrame? {
        guard spriteVersionNumber == 2 else { return nil }
        let deltaX = point.x - mascotBounds.midX
        let deltaY = point.y - mascotBounds.midY
        guard hypot(deltaX, deltaY) > deadzoneRadius else { return nil }

        let degrees = (atan2(deltaX, deltaY) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let directionIndex = Int((degrees / angleStep).rounded()) % directionCount
        return CodexPetFrame(
            rowIndex: startingRow + directionIndex / CodexPetAnimationContract.columnCount,
            columnIndex: directionIndex % CodexPetAnimationContract.columnCount,
            frameDuration: 0
        )
    }
}

@MainActor
enum CodexPetSprites {
    static let frameSize = CodexPetAnimationContract.cellSize

    private static let frameImages: [NSImage?] = {
        guard let url = Bundle.module.url(
            forResource: "spritesheet",
            withExtension: "webp",
            subdirectory: "Pets/codex"
        ), let spriteSheet = NSImage(contentsOf: url),
           let source = spriteSheet.cgImage(forProposedRect: nil, context: nil, hints: nil),
           source.width == Int(frameSize.width) * CodexPetAnimationContract.columnCount,
           source.height == Int(frameSize.height) * CodexPetAnimationContract.rowCount else {
            return []
        }

        return (0..<CodexPetAnimationContract.rowCount).flatMap { rowIndex in
            (0..<CodexPetAnimationContract.columnCount).map { columnIndex in
                let frameRect = CGRect(
                    x: columnIndex * Int(frameSize.width),
                    y: rowIndex * Int(frameSize.height),
                    width: Int(frameSize.width),
                    height: Int(frameSize.height)
                )
                guard let cropped = source.cropping(to: frameRect) else { return nil }
                return NSImage(cgImage: cropped, size: frameSize)
            }
        }
    }()

    static var isValid: Bool {
        frameImages.count == CodexPetAnimationContract.columnCount * CodexPetAnimationContract.rowCount
            && frameImages.allSatisfy { $0 != nil }
    }

    static func image(for frame: CodexPetFrame) -> NSImage? {
        guard (0..<CodexPetAnimationContract.rowCount).contains(frame.rowIndex),
              (0..<CodexPetAnimationContract.columnCount).contains(frame.columnIndex) else {
            return nil
        }
        let index = frame.rowIndex * CodexPetAnimationContract.columnCount + frame.columnIndex
        return frameImages[index]
    }
}

struct CodexPetNormalizedPosition: Equatable, Sendable {
    var x: CGFloat
    var y: CGFloat

    static let bottomTrailing = CodexPetNormalizedPosition(x: 1, y: 0)

    var clamped: CodexPetNormalizedPosition {
        CodexPetNormalizedPosition(x: min(max(x, 0), 1), y: min(max(y, 0), 1))
    }
}

enum CodexPetPositioning {
    static func frame(
        in movementBounds: NSRect,
        size: NSSize,
        normalizedPosition: CodexPetNormalizedPosition
    ) -> NSRect {
        let normalizedPosition = normalizedPosition.clamped
        let horizontalTravel = max(0, movementBounds.width - size.width)
        let verticalTravel = max(0, movementBounds.height - size.height)
        return NSRect(
            x: movementBounds.minX + horizontalTravel * normalizedPosition.x,
            y: movementBounds.minY + verticalTravel * normalizedPosition.y,
            width: size.width,
            height: size.height
        )
    }

    static func normalizedPosition(
        for frame: NSRect,
        in movementBounds: NSRect
    ) -> CodexPetNormalizedPosition {
        let horizontalTravel = max(0, movementBounds.width - frame.width)
        let verticalTravel = max(0, movementBounds.height - frame.height)
        return CodexPetNormalizedPosition(
            x: horizontalTravel == 0 ? 0 : (frame.minX - movementBounds.minX) / horizontalTravel,
            y: verticalTravel == 0 ? 0 : (frame.minY - movementBounds.minY) / verticalTravel
        ).clamped
    }

    static func clampedOrigin(for frame: NSRect, in movementBounds: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(frame.minX, movementBounds.minX), max(movementBounds.minX, movementBounds.maxX - frame.width)),
            y: min(max(frame.minY, movementBounds.minY), max(movementBounds.minY, movementBounds.maxY - frame.height))
        )
    }
}

enum CodexPetPositionStore {
    private static let xKey = "axiom.codex-pet.normalized-x"
    private static let yKey = "axiom.codex-pet.normalized-y"

    static func load(defaults: UserDefaults = .standard) -> CodexPetNormalizedPosition {
        guard defaults.object(forKey: xKey) != nil, defaults.object(forKey: yKey) != nil else {
            return .bottomTrailing
        }
        return CodexPetNormalizedPosition(
            x: defaults.double(forKey: xKey),
            y: defaults.double(forKey: yKey)
        ).clamped
    }

    static func save(_ position: CodexPetNormalizedPosition, defaults: UserDefaults = .standard) {
        let position = position.clamped
        defaults.set(position.x, forKey: xKey)
        defaults.set(position.y, forKey: yKey)
    }
}

@MainActor
final class PetOverlayView: NSView {
    static let defaultWidth: CGFloat = 112
    static let defaultSize = NSSize(
        width: defaultWidth,
        height: defaultWidth * CodexPetAnimationContract.cellSize.height / CodexPetAnimationContract.cellSize.width
    )

    private struct DragSession {
        let startPointer: NSPoint
        let startOrigin: NSPoint
        var lastAcceptedPointer: NSPoint
        var hasMoved: Bool
    }

    private final class PixelatedImageView: NSImageView {
        override func draw(_ dirtyRect: NSRect) {
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current?.imageInterpolation = .none
            super.draw(dirtyRect)
        }
    }

    private let imageView = PixelatedImageView()
    private var activityState: CodexPetAnimationState = .idle
    private var dragAnimationState: CodexPetAnimationState?
    private var activeAnimationState: CodexPetAnimationState?
    private var playback = CodexPetPlayback(frames: [], loopStartIndex: nil)
    private var playbackIndex = 0
    private var frameTimer: Timer?
    private var trackingAreaReference: NSTrackingArea?
    private var dragSession: DragSession?
    private var observesDisplayOptions = false
    private var isHovered = false
    private var movementBoundsProvider: (() -> NSRect)?
    private var onDragEnded: ((NSRect) -> Void)?

    private(set) var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.setAccessibilityElement(false)
        addSubview(imageView)
        isHidden = !CodexPetSprites.isValid
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Codex pet")
    }

    required init?(coder: NSCoder) { nil }

    func configureDragging(
        movementBoundsProvider: @escaping () -> NSRect,
        onDragEnded: @escaping (NSRect) -> Void
    ) {
        self.movementBoundsProvider = movementBoundsProvider
        self.onDragEnded = onDragEnded
    }

    func setActivityState(_ state: CodexPetAnimationState) {
        guard activityState != state else { return }
        activityState = state
        transitionToEffectiveState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            stopAnimation()
            stopObservingDisplayOptions()
        } else {
            startObservingDisplayOptions()
            transitionToEffectiveState(force: true)
        }
    }

    override func layout() {
        super.layout()
        imageView.frame = scaledImageFrame
    }

    override func updateTrackingAreas() {
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaReference = area
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: isDragging ? .closedHand : .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        transitionToEffectiveState()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        transitionToEffectiveState()
    }

    override func mouseDown(with event: NSEvent) {
        guard event.buttonNumber == 0, let superview else {
            super.mouseDown(with: event)
            return
        }
        let pointer = superview.convert(event.locationInWindow, from: nil)
        dragSession = DragSession(
            startPointer: pointer,
            startOrigin: frame.origin,
            lastAcceptedPointer: pointer,
            hasMoved: false
        )
        isDragging = true
        dragAnimationState = nil
        animateDraggingAppearance()
        transitionToEffectiveState()
        window?.invalidateCursorRects(for: self)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var dragSession, let superview else { return }
        let pointer = superview.convert(event.locationInWindow, from: nil)
        let horizontalDelta = pointer.x - dragSession.lastAcceptedPointer.x
        let verticalDelta = pointer.y - dragSession.lastAcceptedPointer.y
        guard abs(horizontalDelta) >= CodexPetAnimationContract.dragThreshold
                || abs(verticalDelta) >= CodexPetAnimationContract.dragThreshold else {
            return
        }

        dragSession.hasMoved = true
        dragSession.lastAcceptedPointer = pointer
        let newDragState = CodexPetAnimationContract.dragState(
            currentState: dragAnimationState,
            horizontalDelta: horizontalDelta
        )
        if newDragState != dragAnimationState {
            dragAnimationState = newDragState
            transitionToEffectiveState()
        }

        let desiredFrame = NSRect(
            origin: NSPoint(
                x: dragSession.startOrigin.x + pointer.x - dragSession.startPointer.x,
                y: dragSession.startOrigin.y + pointer.y - dragSession.startPointer.y
            ),
            size: frame.size
        )
        if let movementBounds = movementBoundsProvider?() {
            frame.origin = CodexPetPositioning.clampedOrigin(for: desiredFrame, in: movementBounds)
        } else {
            frame.origin = desiredFrame.origin
        }
        self.dragSession = dragSession
    }

    override func mouseUp(with event: NSEvent) {
        guard let dragSession else {
            super.mouseUp(with: event)
            return
        }
        self.dragSession = nil
        isDragging = false
        dragAnimationState = nil
        animateDraggingAppearance()
        transitionToEffectiveState()
        window?.invalidateCursorRects(for: self)
        if dragSession.hasMoved { onDragEnded?(frame) }
    }

    private var prefersReducedMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var scaledImageFrame: NSRect {
        let scale = isDragging ? CodexPetAnimationContract.dragScale : 1
        let width = bounds.width * scale
        let height = bounds.height * scale
        return NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)
    }

    private func transitionToEffectiveState(force: Bool = false) {
        let state = CodexPetAnimationContract.effectiveState(
            activityState: activityState,
            isHovered: isHovered,
            dragState: dragAnimationState
        )
        guard force || activeAnimationState != state else { return }
        activeAnimationState = state
        startAnimation(state: state)
    }

    private func startAnimation(state: CodexPetAnimationState) {
        stopAnimation()
        playback = CodexPetAnimationContract.playback(
            for: state,
            prefersReducedMotion: prefersReducedMotion
        )
        playbackIndex = 0
        showCurrentFrame()
        scheduleNextFrameIfNeeded()
    }

    private func stopAnimation() {
        frameTimer?.invalidate()
        frameTimer = nil
    }

    private func showCurrentFrame() {
        guard playback.frames.indices.contains(playbackIndex) else { return }
        imageView.image = CodexPetSprites.image(for: playback.frames[playbackIndex])
    }

    private func scheduleNextFrameIfNeeded() {
        guard playback.frames.count > 1, playback.frames.indices.contains(playbackIndex) else { return }
        let timer = Timer(
            timeInterval: playback.frames[playbackIndex].frameDuration,
            target: self,
            selector: #selector(advanceFrame),
            userInfo: nil,
            repeats: false
        )
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func advanceFrame() {
        frameTimer = nil
        guard window != nil else { return }
        let nextIndex = playbackIndex + 1
        if playback.frames.indices.contains(nextIndex) {
            playbackIndex = nextIndex
        } else if let loopStartIndex = playback.loopStartIndex,
                  playback.frames.indices.contains(loopStartIndex) {
            playbackIndex = loopStartIndex
        } else {
            return
        }
        showCurrentFrame()
        scheduleNextFrameIfNeeded()
    }

    private func animateDraggingAppearance() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = prefersReducedMotion ? 0 : CodexPetAnimationContract.dragScaleDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            imageView.animator().frame = scaledImageFrame
        }
    }

    private func startObservingDisplayOptions() {
        guard !observesDisplayOptions else { return }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(displayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        observesDisplayOptions = true
    }

    private func stopObservingDisplayOptions() {
        guard observesDisplayOptions else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(
            self,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
        observesDisplayOptions = false
    }

    @objc private func displayOptionsDidChange() {
        transitionToEffectiveState(force: true)
        imageView.frame = scaledImageFrame
    }
}
