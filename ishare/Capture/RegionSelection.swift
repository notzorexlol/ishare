//
//  RegionSelection.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import AppKit
import Foundation

/// Fullscreen frozen-screen overlay where the user drags a region to crop
/// before the annotation editor appears.
@MainActor
final class RegionSelectionController: NSObject {
    static var current: RegionSelectionController?

    private let image: NSImage
    private let completion: (CGRect?) -> Void
    private var window: NSWindow?
    private var selectionView: RegionSelectionNSView?

    init(image: NSImage, completion: @escaping (CGRect?) -> Void) {
        self.image = image
        self.completion = completion
        super.init()
    }

    func present() {
        RegionSelectionController.current = self

        let screen = NSScreen.main ?? NSScreen.screens.first!

        let window = NSWindow(
            contentRect: screen.frame, styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.level = .screenSaver
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false

        let view = RegionSelectionNSView(image: image) { [weak self] rect in
            self?.finish(rect)
        }
        window.contentView = view
        selectionView = view

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        selectionView = nil
        completion(rect)
        RegionSelectionController.current = nil
    }
}

/// Borderless fullscreen view: draws the frozen screenshot, lets the user
/// drag a selection, and reports the crop rect in image pixel coordinates
/// (top-left origin, y-down).
@MainActor
final class RegionSelectionNSView: NSView {
    private let image: NSImage
    private let completion: (CGRect?) -> Void

    private var selection: CGRect?
    private var startPoint: NSPoint?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(image: NSImage, completion: @escaping (CGRect?) -> Void) {
        self.image = image
        self.completion = completion
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var imageRect: CGRect {
        let size = image.size
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

    private var imagePixelSize: CGSize {
        if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return CGSize(width: cg.width, height: cg.height)
        }
        return image.size
    }

    private func viewToImage(_ viewRect: CGRect) -> CGRect {
        let displayed = imageRect
        let pixels = imagePixelSize
        guard displayed.width > 0 else { return viewRect }
        let scaleX = pixels.width / displayed.width
        let scaleY = pixels.height / displayed.height
        return CGRect(
            x: (viewRect.minX - displayed.minX) * scaleX,
            y: (viewRect.minY - displayed.minY) * scaleY,
            width: viewRect.width * scaleX,
            height: viewRect.height * scaleY)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current else { return }

        let displayed = imageRect

        // Frozen screenshot
        if displayed.width > 0, displayed.height > 0 {
            image.draw(in: displayed, from: .zero, operation: .sourceOver, fraction: 1)
        }

        // Dim everything outside the selection
        context.cgContext.saveGState()
        context.cgContext.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        if let selection {
            context.cgContext.addRect(bounds)
            context.cgContext.addRect(selection)
            context.cgContext.clip(using: .evenOdd)
        }
        context.cgContext.fill(bounds)
        context.cgContext.restoreGState()

        // Selection border + size label
        if let selection {
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: selection)
            border.lineWidth = 1.5
            border.stroke()

            let pixels = viewToImage(selection)
            let label = "\(Int(round(pixels.width))) × \(Int(round(pixels.height)))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.white,
            ]
            let attributed = NSAttributedString(string: label, attributes: attributes)
            let labelSize = attributed.size()
            var labelOrigin = CGPoint(
                x: selection.minX,
                y: selection.maxY + 8)
            if labelOrigin.y + labelSize.height > bounds.maxY {
                labelOrigin.y = selection.minY - labelSize.height - 8
            }
            attributed.draw(at: labelOrigin)
        }
    }

    // MARK: Mouse events

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        startPoint = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let point = convert(event.locationInWindow, from: nil)
        selection = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let selection, selection.width > 2, selection.height > 2 else {
            startPoint = nil
            self.selection = nil
            needsDisplay = true
            return
        }
        startPoint = nil
        self.selection = nil
        completion(viewToImage(selection))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // escape
            completion(nil)
        } else {
            super.keyDown(with: event)
        }
    }
}
