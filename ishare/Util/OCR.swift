//
//  OCR.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import AppKit
import BezelNotification
import Defaults
import Foundation
import Vision

/// Drags over a region of the screen (like a screenshot) and copies the
/// recognized text to the clipboard.
@MainActor
func performOCRFromScreen() async {
    NSLog("Starting OCR capture from screen")

    let fileType = Defaults[.captureFileType]
    let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "ishare-ocr-\(UUID().uuidString).\(fileType.rawValue)")

    let task = Process()
    task.launchPath = Defaults[.captureBinary]
    task.arguments = ["-it", fileType.rawValue, tempURL.path]

    NSLog("Executing capture command: %@ -it %@", Defaults[.captureBinary], tempURL.path)
    task.launch()
    task.waitUntilExit()

    guard FileManager.default.fileExists(atPath: tempURL.path) else {
        NSLog("OCR capture cancelled, no region selected")
        return
    }
    NSLog("OCR capture completed, recognizing text")

    let recognizedText = await Task.detached(priority: .userInitiated) {
        recognizeText(in: tempURL)
    }.value

    try? FileManager.default.removeItem(at: tempURL)

    guard let recognizedText, !recognizedText.isEmpty else {
        NSLog("OCR: no text recognized")
        BezelNotification.show(messageText: "No text found".localized(), icon: ToastIcon)
        return
    }

    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(recognizedText, forType: .string)

    let preview = String(recognizedText.split(whereSeparator: { $0.isNewline }).joined(separator: " ").prefix(60))
    NSLog("OCR text copied: %@", recognizedText)
    BezelNotification.show(messageText: preview, icon: ToastIcon)
    NSSound.beep()
}

/// Runs Vision text recognition over the image at the given URL.
func recognizeText(in fileURL: URL) -> String? {
    guard let image = NSImage(contentsOf: fileURL),
        let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    else {
        NSLog("OCR: failed to load image at %@", fileURL.path)
        return nil
    }

    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage)
    do {
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    } catch {
        NSLog("OCR failed: %@", error.localizedDescription)
        return nil
    }
}
