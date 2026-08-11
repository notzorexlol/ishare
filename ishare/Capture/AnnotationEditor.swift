//
//  AnnotationEditor.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import AppKit
import SwiftUI

// MARK: - Editor window controller

@MainActor
final class AnnotationEditorController: NSObject {
    static var current: AnnotationEditorController?

    private let image: NSImage
    private let cgImage: CGImage
    private let pixelatedImage: NSImage?
    private let completion: (NSImage?) -> Void

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnnotationEditorView>?

    init(image: NSImage, completion: @escaping (NSImage?) -> Void) {
        self.image = image
        self.completion = completion
        self.cgImage =
            image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            ?? NSImage(size: NSSize(width: 1, height: 1)).cgImage(forProposedRect: nil, context: nil, hints: nil)!
        self.pixelatedImage = makePixelatedImage(from: cgImage)
        super.init()
    }

    func present() {
        AnnotationEditorController.current = self

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let frame = screen.frame

        let window = NSWindow(
            contentRect: frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = AnnotationEditorView(
            image: image, cgImage: cgImage, pixelatedImage: pixelatedImage
        ) { [weak self] result in
            self?.finish(result)
        }
        let hosting = NSHostingView(rootView: view)
        window.contentView = hosting
        self.hostingView = hosting

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func finish(_ result: NSImage?) {
        window?.orderOut(nil)
        window = nil
        hostingView = nil
        completion(result)
        AnnotationEditorController.current = nil
    }
}

// MARK: - SwiftUI editor view

@MainActor
struct AnnotationEditorView: View {
    let image: NSImage
    let cgImage: CGImage
    let pixelatedImage: NSImage?
    let completion: (NSImage?) -> Void

    @State private var tool: AnnotationTool = .pen
    @State private var strokeColor: NSColor = .red
    @State private var lineWidth: CGFloat = 6

    @State private var annotations: [Annotation] = []
    @State private var draft: Annotation?
    @State private var selectedID: UUID?

    @State private var undoStack: [[Annotation]] = []
    @State private var redoStack: [[Annotation]] = []

    @State private var showTextEditor = false
    @State private var pendingText = ""
    @State private var textTap: (imagePoint: CGPoint, viewPoint: CGPoint)?

    private let palette: [NSColor] = [
        .red, .orange, .yellow, .green, .cyan, .blue, .purple, .systemPink, .white, .black,
    ]

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            AnnotationCanvasRepresentable(
                displayImage: image, cgImage: cgImage, pixelatedImage: pixelatedImage,
                annotations: $annotations,
                draft: $draft,
                selectedID: $selectedID,
                tool: tool,
                strokeColor: strokeColor,
                lineWidth: lineWidth,
                onWillBegin: { willBegin() },
                onTextTap: { imagePoint, viewPoint in
                    textTap = (imagePoint, viewPoint)
                    pendingText = ""
                    showTextEditor = true
                },
                onCommit: { annotation in
                    annotations.append(annotation)
                },
                onMove: { moved in
                    if let index = annotations.firstIndex(where: { $0.id == moved.id }) {
                        annotations[index] = moved
                    }
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack {
                toolbar
                Spacer()
            }

            if showTextEditor, let textTap {
                textEditorOverlay(tap: textTap)
            }
        }
        .onExitCommand {
            cancel()
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { t in
                Button {
                    tool = t
                } label: {
                    Image(systemName: t.symbolName)
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    tool == t ? Color.accentColor.opacity(0.35) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
                .help(t.title)
            }

            Divider().frame(height: 24)

            ForEach(palette, id: \.self) { color in
                Button {
                    strokeColor = color
                } label: {
                    Circle()
                        .fill(Color(color))
                        .frame(width: 18, height: 18)
                        .overlay(
                            Circle().stroke(
                                strokeColor == color ? Color.white : Color.white.opacity(0.3),
                                lineWidth: strokeColor == color ? 2 : 1))
                }
                .buttonStyle(.plain)
            }

            ColorPicker("", selection: colorBinding, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 34)

            Divider().frame(height: 24)

            Slider(value: $lineWidth, in: 1...24)
                .frame(width: 100)

            Divider().frame(height: 24)

            Button {
                undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(undoStack.isEmpty)
            .help("Undo")

            Button {
                redo()
            } label: {
                Image(systemName: "arrow.uturn.forward")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(redoStack.isEmpty)
            .help("Redo")

            Button {
                clearAll()
            } label: {
                Image(systemName: "trash")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .disabled(annotations.isEmpty)
            .help("Clear annotations")

            Spacer()

            Button {
                cancel()
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("Cancel")

            Button {
                confirm()
            } label: {
                Image(systemName: "checkmark")
                    .font(.system(size: 16, weight: .bold))
                    .frame(width: 32, height: 26)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .help("Done")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.15))
        )
        .padding(.top, 10)
        .padding(.horizontal, 16)
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(strokeColor) },
            set: { strokeColor = NSColor($0) }
        )
    }

    // MARK: Text overlay

    private func textEditorOverlay(tap: (imagePoint: CGPoint, viewPoint: CGPoint)) -> some View {
        TextField("", text: $pendingText)
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .padding(8)
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5))
            .frame(width: 280)
            .position(
                x: max(160, min(tap.viewPoint.x + 140, (NSScreen.main?.frame.width ?? 800) - 140)),
                y: max(20, tap.viewPoint.y + 20))
            .onSubmit {
                addTextAnnotation()
            }
    }

    private func addTextAnnotation() {
        defer { showTextEditor = false }
        let trimmed = pendingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let tap = textTap else { return }
        willBegin()
        let annotation = Annotation(
            tool: .text, color: strokeColor, lineWidth: lineWidth,
            startPoint: tap.imagePoint, endPoint: tap.imagePoint,
            text: trimmed, fontPointSize: 32)
        annotations.append(annotation)
    }

    // MARK: Actions

    private func willBegin() {
        undoStack.append(annotations)
        if undoStack.count > 50 { undoStack.removeFirst() }
        redoStack = []
    }

    private func undo() {
        guard let snapshot = undoStack.popLast() else { return }
        redoStack.append(annotations)
        annotations = snapshot
        selectedID = nil
    }

    private func redo() {
        guard let snapshot = redoStack.popLast() else { return }
        undoStack.append(annotations)
        annotations = snapshot
        selectedID = nil
    }

    private func clearAll() {
        guard !annotations.isEmpty else { return }
        willBegin()
        annotations = []
        selectedID = nil
    }

    private func cancel() {
        completion(nil)
    }

    private func confirm() {
        guard let finalImage = renderFinalAnnotatedImage(
            cgImage: cgImage, pixelatedImage: pixelatedImage, annotations: annotations)
        else {
            completion(nil)
            return
        }
        completion(finalImage)
    }
}

// MARK: - NSView canvas

struct AnnotationCanvasRepresentable: NSViewRepresentable {
    let displayImage: NSImage
    let cgImage: CGImage
    let pixelatedImage: NSImage?

    @Binding var annotations: [Annotation]
    @Binding var draft: Annotation?
    @Binding var selectedID: UUID?

    var tool: AnnotationTool
    var strokeColor: NSColor
    var lineWidth: CGFloat

    var onWillBegin: () -> Void
    var onTextTap: (CGPoint, CGPoint) -> Void
    var onCommit: (Annotation) -> Void
    var onMove: (Annotation) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> AnnotationCanvasNSView {
        let view = AnnotationCanvasNSView(
            displayImage: displayImage, cgImage: cgImage, pixelatedImage: pixelatedImage)
        view.tool = tool
        view.strokeColor = strokeColor
        view.lineWidth = lineWidth
        view.annotations = annotations
        view.onWillBegin = { context.coordinator.parent.onWillBegin() }
        view.onTextTap = { imagePoint, viewPoint in
            context.coordinator.parent.onTextTap(imagePoint, viewPoint)
        }
        view.onCommit = { annotation in
            context.coordinator.parent.onCommit(annotation)
        }
        view.onMove = { moved in
            context.coordinator.parent.onMove(moved)
        }
        return view
    }

    func updateNSView(_ nsView: AnnotationCanvasNSView, context: Context) {
        nsView.tool = tool
        nsView.strokeColor = strokeColor
        nsView.lineWidth = lineWidth
        nsView.annotations = annotations
        nsView.selectedID = selectedID
        nsView.needsDisplay = true
    }

    final class Coordinator {
        var parent: AnnotationCanvasRepresentable
        init(_ parent: AnnotationCanvasRepresentable) {
            self.parent = parent
        }
    }
}

@MainActor
final class AnnotationCanvasNSView: NSView {
    let displayImage: NSImage
    let cgImage: CGImage
    let pixelatedImage: NSImage?

    var tool: AnnotationTool = .pen
    var strokeColor: NSColor = .red
    var lineWidth: CGFloat = 6
    var annotations: [Annotation] = []
    var draft: Annotation?
    var selectedID: UUID?

    var onWillBegin: (() -> Void)?
    var onTextTap: ((CGPoint, CGPoint) -> Void)?
    var onCommit: ((Annotation) -> Void)?
    var onMove: ((Annotation) -> Void)?

    private var moveStart: (annotation: Annotation, viewPoint: CGPoint)?

    private var imagePixelSize: CGSize {
        CGSize(width: cgImage.width, height: cgImage.height)
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(displayImage: NSImage, cgImage: CGImage, pixelatedImage: NSImage?) {
        self.displayImage = displayImage
        self.cgImage = cgImage
        self.pixelatedImage = pixelatedImage
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Geometry

    func imageRect() -> CGRect {
        let size = imagePixelSize
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else {
            return .zero
        }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let scaled = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: (bounds.width - scaled.width) / 2,
            y: (bounds.height - scaled.height) / 2,
            width: scaled.width, height: scaled.height)
    }

    private func viewToImage(_ point: CGPoint) -> CGPoint {
        let rect = imageRect()
        guard rect.width > 0 else { return point }
        let scale = imagePixelSize.width / rect.width
        return CGPoint(x: (point.x - rect.minX) * scale, y: (point.y - rect.minY) * scale)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }
        context.cgContext.setFillColor(NSColor.black.cgColor)
        context.cgContext.fill(bounds)

        let rect = imageRect()
        if rect.width > 0, rect.height > 0 {
            displayImage.draw(in: rect)
        }

        for annotation in annotations {
            annotation.draw(
                in: context, imageSize: imagePixelSize, pixelatedImage: pixelatedImage)
            if annotation.id == selectedID {
                drawSelectionOutline(annotation, in: context)
            }
        }
        if let draft {
            draft.draw(in: context, imageSize: imagePixelSize, pixelatedImage: pixelatedImage)
        }
    }

    private func drawSelectionOutline(_ annotation: Annotation, in context: NSGraphicsContext) {
        let box = annotation.tool == .text ? annotation.textBounds : annotation.rect
        let outline = box.insetBy(dx: -4, dy: -4)
        let path = NSBezierPath(rect: outline)
        path.lineWidth = 1
        let dashes: [CGFloat] = [4, 3]
        path.setLineDash(dashes, count: 2, phase: 0)
        NSColor.white.setStroke()
        path.stroke()
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)
        let imagePoint = viewToImage(viewPoint)

        switch tool {
        case .pointer:
            if let index = annotationHitTest(imagePoint) {
                selectedID = annotations[index].id
                moveStart = (annotations[index], viewPoint)
                onWillBegin?()
            } else {
                selectedID = nil
            }
            needsDisplay = true
        case .text:
            onTextTap?(imagePoint, viewPoint)
        default:
            var newDraft = makeDraft(at: imagePoint)
            newDraft.endPoint = imagePoint
            draft = newDraft
            needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        if let move = moveStart {
            let delta = CGSize(
                width: viewPoint.x - move.viewPoint.x, height: viewPoint.y - move.viewPoint.y)
            let moved = move.annotation.translated(by: delta)
            if let index = annotations.firstIndex(where: { $0.id == move.annotation.id }) {
                annotations[index] = moved
            }
            needsDisplay = true
        } else if var currentDraft = draft {
            let imagePoint = viewToImage(viewPoint)
            currentDraft.endPoint = imagePoint
            if currentDraft.tool == .pen {
                if let last = currentDraft.points.last,
                    hypot(last.x - imagePoint.x, last.y - imagePoint.y) < 1.5
                {
                    // skip too-close points
                } else {
                    currentDraft.points.append(imagePoint)
                }
            }
            draft = currentDraft
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)

        if let move = moveStart {
            moveStart = nil
            if let index = annotations.firstIndex(where: { $0.id == move.annotation.id }) {
                onMove?(annotations[index])
            }
        } else if var currentDraft = draft {
            let imagePoint = viewToImage(viewPoint)
            currentDraft.endPoint = imagePoint
            if currentDraft.tool == .pen {
                currentDraft.points.append(imagePoint)
            }
            draft = nil

            let isValid = currentDraft.tool == .pen
                ? currentDraft.points.count >= 2
                : (currentDraft.rect.width > 2 && currentDraft.rect.height > 2)
            if isValid {
                onWillBegin?()
                onCommit?(currentDraft)
            }
        }
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117 { // delete / forward delete
            if let selectedID {
                onWillBegin?()
                annotations.removeAll { $0.id == selectedID }
                self.selectedID = nil
                needsDisplay = true
            }
        } else {
            super.keyDown(with: event)
        }
    }

    // MARK: Helpers

    private func makeDraft(at point: CGPoint) -> Annotation {
        Annotation(
            tool: tool, color: strokeColor, lineWidth: lineWidth,
            startPoint: point, endPoint: point,
            points: tool == .pen ? [point] : [])
    }

    private func annotationHitTest(_ point: CGPoint) -> Int? {
        var hitIndex: Int?
        for (index, annotation) in annotations.enumerated() where annotation.contains(point, tolerance: 12) {
            hitIndex = index
        }
        return hitIndex
    }
}
