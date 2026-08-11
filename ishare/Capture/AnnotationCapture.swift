//
//  AnnotationCapture.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import AppKit
import Defaults
import Foundation

/// Captures an image, runs it through the region selector (for region
/// captures) and the annotation editor, then applies the normal post-capture
/// pipeline (copy / save / upload / share).
@MainActor
func captureScreenWithAnnotation(type: CaptureType, display: Int) async {
    NSLog("Starting annotated capture with type: %@, display: %d", type.rawValue, display)

    guard let sourceImage = captureSourceImage(type: type, display: display) else {
        NSLog("Annotated capture: failed to capture source image")
        return
    }

    var editImage = sourceImage

    if type == .REGION {
        guard let cropRect = await presentRegionSelection(sourceImage) else {
            NSLog("Annotated capture: region selection cancelled")
            return
        }
        editImage = cropImage(sourceImage, toPixelRect: cropRect)
    }

    guard let finalImage = await presentAnnotationEditor(image: editImage) else {
        NSLog("Annotated capture: annotation editor cancelled")
        return
    }

    await saveAnnotatedImage(finalImage, type: type, display: display)
}

// MARK: - Source image

@MainActor
private func captureSourceImage(type: CaptureType, display: Int) -> NSImage? {
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ishare-annotate-\(UUID().uuidString).png")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let arguments: [String]
    switch type {
    case .SCREEN:
        arguments = ["-t", "png", "-D", "\(display)", tempURL.path]
    case .REGION:
        arguments = ["-t", "png", "-D", "\(displayIDUnderMouse())", tempURL.path]
    case .WINDOW:
        if let windowID = frontmostWindowID() {
            arguments = ["-t", "png", "-l", "\(windowID)", tempURL.path]
        } else {
            arguments = ["-t", "png", "-D", "\(display)", tempURL.path]
        }
    }

    let task = Process()
    task.launchPath = Defaults[.captureBinary]
    task.arguments = arguments
    NSLog("Annotated capture: executing %@ %@", task.launchPath ?? "", arguments.joined(separator: " "))
    task.launch()
    task.waitUntilExit()

    guard FileManager.default.fileExists(atPath: tempURL.path) else {
        NSLog("Annotated capture: no image produced")
        return nil
    }
    return NSImage(contentsOf: tempURL)
}

private func displayIDUnderMouse() -> Int {
    let mouse = NSEvent.mouseLocation
    for (index, screen) in NSScreen.screens.enumerated() where NSPointInRect(mouse, screen.frame) {
        return index + 1
    }
    return 1
}

private func frontmostWindowID() -> CGWindowID? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
    let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
    guard
        let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
    else { return nil }

    let candidate = infoList
        .filter { ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid }
        .filter { ($0[kCGWindowLayer as String] as? NSNumber)?.intValue == 0 }
        .filter { (($0[kCGWindowName as String] as? String) ?? "").isEmpty == false }
        .max { a, b in
            let aRect = (a[kCGWindowBounds as String] as? [String: Any]) ?? [:]
            let bRect = (b[kCGWindowBounds as String] as? [String: Any]) ?? [:]
            let aArea =
                ((aRect["Width"] as? NSNumber)?.doubleValue ?? 0)
                * ((aRect["Height"] as? NSNumber)?.doubleValue ?? 0)
            let bArea =
                ((bRect["Width"] as? NSNumber)?.doubleValue ?? 0)
                * ((bRect["Height"] as? NSNumber)?.doubleValue ?? 0)
            return aArea < bArea
        }

    guard let candidate else { return nil }
    return CGWindowID(((candidate[kCGWindowNumber as String] as? NSNumber)?.uint32Value) ?? 0)
}

// MARK: - Crop / presentation

@MainActor
private func cropImage(_ image: NSImage, toPixelRect pixelRect: CGRect) -> NSImage {
    guard
        let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
        pixelRect.width > 0, pixelRect.height > 0
    else { return image }

    let cropRect = CGRect(
        x: pixelRect.minX,
        y: CGFloat(cg.height) - pixelRect.maxY,
        width: pixelRect.width,
        height: pixelRect.height)

    guard let cropped = cg.cropping(to: cropRect) else { return image }
    return NSImage(
        cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
}

@MainActor
private func presentRegionSelection(_ image: NSImage) async -> CGRect? {
    await withCheckedContinuation { continuation in
        let controller = RegionSelectionController(image: image) { rect in
            continuation.resume(returning: rect)
        }
        controller.present()
    }
}

@MainActor
private func presentAnnotationEditor(image: NSImage) async -> NSImage? {
    await withCheckedContinuation { continuation in
        let controller = AnnotationEditorController(image: image) { result in
            continuation.resume(returning: result)
        }
        controller.present()
    }
}

// MARK: - Save + post processing

@MainActor
private func saveAnnotatedImage(_ image: NSImage, type: CaptureType, display: Int) async {
    let capturePath = Defaults[.capturePath]
    let fileType = Defaults[.captureFileType]
    let fileName = Defaults[.captureFileName]

    let suffix = await getCaptureNameSuffix(type: type, display: display)
    let timestamp = Int(Date().timeIntervalSince1970)
    let uniqueFilename = "\(fileName)-\(timestamp)\(suffix).\(fileType.rawValue)"
    var path = "\(capturePath)\(uniqueFilename)"
    path = NSString(string: path).expandingTildeInPath

    let fileURL = URL(fileURLWithPath: path)
    if !writeImage(image, to: fileURL, fileType: fileType) {
        NSLog("Annotated capture: failed to write annotated image to %@", path)
        return
    }

    NSLog("Annotated capture: saved to %@", path)
    postCaptureTasks(fileURL: fileURL)
}

@MainActor
private func writeImage(_ image: NSImage, to url: URL, fileType: FileType) -> Bool {
    guard
        let tiff = image.tiffRepresentation,
        let rep = NSBitmapImageRep(data: tiff)
    else { return false }

    let data: Data?
    switch fileType {
    case .PNG, .HEIC, .PDF:
        data = rep.representation(using: .png, properties: [:])
    case .JPG:
        data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.9])
    case .TIFF:
        data = rep.representation(using: .tiff, properties: [:])
    }

    guard let data else { return false }
    do {
        try data.write(to: url, options: .atomic)
        return true
    } catch {
        NSLog("Annotated capture: failed to write file: %@", error.localizedDescription)
        return false
    }
}
