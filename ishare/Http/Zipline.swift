//
//  Zipline.swift
//  ishare
//
//  Created by Adrian Castro on 11.08.26.
//

import Alamofire
import AppKit
import BezelNotification
import Defaults
import Foundation
import SwiftyJSON

@MainActor func ziplineUpload(_ fileURL: URL, completion: @Sendable @escaping () -> Void) {
    let serverURL = Defaults[.ziplineServerURL]
    let apiToken = Defaults[.ziplineAPIToken]
    let uploadManager = UploadManager.shared

    guard !serverURL.isEmpty, !apiToken.isEmpty else {
        NSLog("Zipline upload: missing server URL or API token")
        showZiplineErrorNotification()
        completion()
        return
    }

    let trimmedServer = serverURL.hasSuffix("/") ? String(serverURL.dropLast()) : serverURL
    let url = trimmedServer + "/api/upload"

    NSLog("Starting Zipline upload for file: %@", fileURL.path)
    let fileName = "ishare.\(fileURL.pathExtension)"
    let mimeType = mimeTypeForPathExtension(fileURL.pathExtension)

    AF.upload(multipartFormData: { multipartFormData in
        multipartFormData.append(
            fileURL, withName: "file", fileName: fileName, mimeType: mimeType)
    }, to: url, method: .post, headers: [
        "Authorization": apiToken,
        "Accept": "application/json",
    ])
        .uploadProgress { progress in
            Task { @MainActor in
                uploadManager.updateProgress(fraction: progress.fractionCompleted)
            }
        }
        .response { response in
            Task { @MainActor in
                uploadManager.uploadCompleted()
                if let data = response.data {
                    let json = JSON(data)
                    if let link = json["files"].array?.first?["url"].string
                        ?? json["url"].string
                    {
                        print("Zipline upload successful. Link: \(link)")

                        if !Defaults[.copyImageToClipboard] {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(link, forType: .string)
                        }

                        let historyItem = HistoryItem(fileUrl: link)
                        addToUploadHistory(historyItem)
                        completion()
                    } else {
                        print("Error parsing Zipline response or retrieving link")
                        showZiplineErrorNotification()
                        completion()
                    }
                } else {
                    print("Zipline upload failed with no response data")
                    showZiplineErrorNotification()
                    completion()
                }
            }
        }
}

@MainActor
private func showZiplineErrorNotification() {
    BezelNotification.show(messageText: "An error occured", icon: ToastIcon)
}
