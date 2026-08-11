//
//  AnnotationModels.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import AppKit
import Foundation
import SwiftUI

/// The tools available in the annotation editor. Mirrors the core ShareX toolset.
enum AnnotationTool: CaseIterable, Identifiable {
    case pointer
    case pen
    case arrow
    case line
    case rectangle
    case ellipse
    case text
    case highlight
    case pixelate

    var id: Self { self }

    var symbolName: String {
        switch self {
        case .pointer: "cursorarrow"
        case .pen: "pencil.tip"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .text: "textformat"
        case .highlight: "highlighter"
        case .pixelate: "square.grid.3x3"
        }
    }

    var title: String {
        switch self {
        case .pointer: "Pointer"
        case .pen: "Pen"
        case .arrow: "Arrow"
        case .line: "Line"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .text: "Text"
        case .highlight: "Highlight"
        case .pixelate: "Pixelate"
        }
    }

    var drawsShapes: Bool {
        switch self {
        case .pointer, .text: false
        default: true
        }
    }
}

/// A single annotation drawn on top of the captured image.
///
/// Coordinates are stored in the *image*'s pixel space using a top-left
/// origin (y increases downward), which matches how the flipped canvas is
/// drawn on screen.
struct Annotation: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var color: NSColor
    var lineWidth: CGFloat
    var startPoint: CGPoint
    var endPoint: CGPoint
    var points: [CGPoint] = []
    var text: String = ""
    var fontPointSize: CGFloat = 32

    var rect: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }

    var textBounds: CGRect {
        CGRect(
            x: startPoint.x,
            y: startPoint.y,
            width: max(200, CGFloat(text.count) * fontPointSize * 0.55),
            height: fontPointSize * 1.4
        )
    }

    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        switch tool {
        case .pointer:
            return false
        case .pen:
            guard !points.isEmpty else { return false }
            var previous = points[0]
            for p in points.dropFirst() {
                if distance(from: point, toSegment: previous, p) <= tolerance { return true }
                previous = p
            }
            return distance(from: point, toSegment: points[0], points[0]) <= tolerance
        case .arrow, .line:
            return distance(from: point, toSegment: startPoint, endPoint) <= tolerance
        case .rectangle, .ellipse, .highlight, .pixelate:
            return rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case .text:
            return textBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        }
    }

    func translated(by delta: CGSize) -> Annotation {
        var copy = self
        copy.startPoint = CGPoint(x: startPoint.x + delta.width, y: startPoint.y + delta.height)
        copy.endPoint = CGPoint(x: endPoint.x + delta.width, y: endPoint.y + delta.height)
        copy.points = points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) }
        return copy
    }
}

private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x
    let dy = b.y - a.y
    if dx == 0, dy == 0 { return hypot(point.x - a.x, point.y - a.y) }
    let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / (dx * dx + dy * dy)))
    let px = a.x + t * dx
    let py = a.y + t * dy
    return hypot(point.x - px, point.y - py)
}

extension Annotation {
    /// Draws the annotation into a flipped (top-left origin) graphics context.
    func draw(in context: NSGraphicsContext, imageSize: CGSize, pixelatedImage: NSImage?) {
        switch tool {
        case .pointer:
            break
        case .pen:
            guard points.count >= 2 else { return }
            let path = NSBezierPath()
            path.move(to: points[0])
            for p in points.dropFirst() { path.line(to: p) }
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
        case .line:
            let path = NSBezierPath()
            path.move(to: startPoint)
            path.line(to: endPoint)
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            color.setStroke()
            path.stroke()
        case .arrow:
            drawArrow(in: context)
        case .rectangle:
            color.setStroke()
            let path = NSBezierPath(rect: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .ellipse:
            color.setStroke()
            let path = NSBezierPath(ovalIn: rect)
            path.lineWidth = lineWidth
            path.stroke()
        case .highlight:
            color.withAlphaComponent(0.35).setFill()
            NSBezierPath(rect: rect).fill()
        case .text:
            drawText()
        case .pixelate:
            guard let pixelatedImage else { return }
            context.cgContext.saveGState()
            context.cgContext.clip(to: rect)
            pixelatedImage.draw(in: NSRect(origin: .zero, size: imageSize))
            context.cgContext.restoreGState()
        }
    }

    private func drawArrow(in context: NSGraphicsContext) {
        let path = NSBezierPath()
        path.move(to: startPoint)
        path.line(to: endPoint)
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()

        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength = max(lineWidth * 4, 14)
        let headWidth = headLength * 0.5
        let tip = endPoint
        let base = CGPoint(
            x: tip.x - cos(angle) * headLength,
            y: tip.y - sin(angle) * headLength
        )
        let perpendicular = angle + .pi / 2
        let left = CGPoint(
            x: base.x + cos(perpendicular) * headWidth,
            y: base.y + sin(perpendicular) * headWidth
        )
        let right = CGPoint(
            x: base.x - cos(perpendicular) * headWidth,
            y: base.y - sin(perpendicular) * headWidth
        )

        let headPath = NSBezierPath()
        headPath.move(to: tip)
        headPath.line(to: left)
        headPath.line(to: base)
        headPath.line(to: right)
        headPath.close()
        color.setFill()
        headPath.fill()
    }

    private func drawText() {
        guard !text.isEmpty else { return }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: color,
            .font: NSFont.systemFont(ofSize: fontPointSize, weight: .semibold),
            .paragraphStyle: paragraph,
        ]
        (text as NSString).draw(at: startPoint, withAttributes: attributes)
    }
}

/// Renders a full-resolution copy of the annotated image.
@MainActor
func renderFinalAnnotatedImage(
    cgImage: CGImage, pixelatedImage: NSImage?, annotations: [Annotation]
) -> NSImage? {
    let width = cgImage.width
    let height = cgImage.height
    guard width > 0, height > 0 else { return nil }

    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let bitmapContext = NSGraphicsContext(bitmapImageRep: rep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    let flippedContext = NSGraphicsContext(cgContext: bitmapContext.cgContext, flipped: true)
    NSGraphicsContext.current = flippedContext

    NSImage(cgImage: cgImage, size: NSSize(width: width, height: height)).draw(
        in: NSRect(x: 0, y: 0, width: width, height: height))

    for annotation in annotations {
        annotation.draw(
            in: flippedContext, imageSize: CGSize(width: width, height: height),
            pixelatedImage: pixelatedImage)
    }

    NSGraphicsContext.restoreGraphicsState()

    let finalImage = NSImage(size: NSSize(width: width, height: height))
    finalImage.addRepresentation(rep)
    return finalImage
}

/// Applies a pixelation filter to the whole image so the pixelate tool can
/// reveal patches of it on demand.
@MainActor
func makePixelatedImage(from cgImage: CGImage) -> NSImage? {
    let ciImage = CIImage(cgImage: cgImage)
    guard let filter = CIFilter(name: "CIPixellate") else { return nil }
    filter.setValue(ciImage, forKey: kCIInputImageKey)
    filter.setValue(NSNumber(value: 12), forKey: kCIInputScaleKey)
    guard let output = filter.outputImage else { return nil }
    let context = CIContext()
    guard let outCGImage = context.createCGImage(output, from: ciImage.extent) else { return nil }
    return NSImage(
        cgImage: outCGImage, size: NSSize(width: cgImage.width, height: cgImage.height))
}
