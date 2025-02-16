// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0/

import Common
import Account
import Shared
import Storage
import Sync
import UserNotifications

class NotificationService: UNNotificationServiceExtension {
    var display: SyncDataDisplay?
    var profile: BrowserProfile?

    // This is run when an APNS notification with `mutable-content` is received.
    // If the app is backgrounded, then the alert notification is displayed.
    // If the app is foregrounded, then the notification.userInfo is passed straight to
    // AppDelegate.application(_:didReceiveRemoteNotification:completionHandler:)
    // Once the notification is tapped, then the same userInfo is passed to the same method in the AppDelegate.
    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let userInfo = request.content.userInfo

        let content = request.content.mutableCopy() as! UNMutableNotificationContent

        if self.profile == nil {
            self.profile = BrowserProfile(localName: "profile")
        }

        guard let profile = self.profile else {
            self.didFinish(with: .noProfile)
            return
        }

        let display = SyncDataDisplay(content: content, contentHandler: contentHandler)
        self.display = display

        let handler = FxAPushMessageHandler(with: profile)

        handler.handle(userInfo: userInfo).upon { res in
            guard res.isSuccess, let event = res.successValue else {
                self.didFinish(nil, with: res.failureValue as? PushMessageError)
                return
            }

            self.didFinish(event)
        }
    }

    func didFinish(_ what: PushMessage? = nil, with error: PushMessageError? = nil) {
        defer {
            profile?.shutdown()
        }

        profile?.setCommandArrived()

        guard let display = self.display else { return }

        display.messageDelivered = false
        display.displayNotification(what, profile: profile, with: error)
        if !display.messageDelivered {
            display.displayUnknownMessageNotification(debugInfo: "Not delivered")
        }
    }

    override func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        didFinish(with: .timeout)
    }
}

class SyncDataDisplay {
    var contentHandler: (UNNotificationContent) -> Void
    var notificationContent: UNMutableNotificationContent

    var tabQueue: TabQueue?
    var messageDelivered = false

    init(content: UNMutableNotificationContent,
         contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.contentHandler = contentHandler
        self.notificationContent = content
    }

    func displayNotification(_ message: PushMessage? = nil, profile: BrowserProfile?, with error: PushMessageError? = nil) {
        guard let message = message, error == nil else {
            return displayUnknownMessageNotification(debugInfo: "Error \(error?.description ?? "")")
        }

        switch message {
        case .commandReceived(let tab):
            displayNewSentTabNotification(tab: tab)
        case .deviceConnected(let deviceName):
            displayDeviceConnectedNotification(deviceName)
        case .deviceDisconnected(let deviceName):
            displayDeviceDisconnectedNotification(deviceName)
        case .thisDeviceDisconnected:
            displayThisDeviceDisconnectedNotification()
        default:
            displayUnknownMessageNotification(debugInfo: "Unknown: \(message)")
            break
        }
    }

    func displayDeviceConnectedNotification(_ deviceName: String) {
        presentNotification(title: .FxAPush_DeviceConnected_title,
                            body: .FxAPush_DeviceConnected_body,
                            bodyArg: deviceName)
    }

    func displayDeviceDisconnectedNotification(_ deviceName: String?) {
        if let deviceName = deviceName {
            presentNotification(title: .FxAPush_DeviceDisconnected_title,
                                body: .FxAPush_DeviceDisconnected_body,
                                bodyArg: deviceName)
        } else {
            // We should never see this branch
            presentNotification(title: .FxAPush_DeviceDisconnected_title,
                                body: .FxAPush_DeviceDisconnected_UnknownDevice_body)
        }
    }

    func displayThisDeviceDisconnectedNotification() {
        presentNotification(title: .FxAPush_DeviceDisconnected_ThisDevice_title,
                            body: .FxAPush_DeviceDisconnected_ThisDevice_body)
    }

    func displayAccountVerifiedNotification() {
        #if MOZ_CHANNEL_BETA || DEBUG
            presentNotification(title: .SentTab_NoTabArrivingNotification_title, body: "DEBUG: Account Verified")
            return
        #else
        presentNotification(title: .SentTab_NoTabArrivingNotification_title, body: .SentTab_NoTabArrivingNotification_body)
        #endif
    }

    func displayUnknownMessageNotification(debugInfo: String) {
        #if MOZ_CHANNEL_BETA || DEBUG
            presentNotification(title: .SentTab_NoTabArrivingNotification_title, body: "DEBUG: " + debugInfo)
            return
        #else
        presentNotification(title: .SentTab_NoTabArrivingNotification_title, body: .SentTab_NoTabArrivingNotification_body)
        #endif
    }

    func displayNewSentTabNotification(tab: [String: String]) {
        if let urlString = tab["url"], let url = URL(string: urlString), url.isWebPage(), let title = tab["title"] {
            let tab = [
                "title": title,
                "url": url.absoluteString,
                "displayURL": url.absoluteDisplayExternalString,
                "deviceName": nil
            ] as NSDictionary

            notificationContent.userInfo["sentTabs"] = [tab] as NSArray

            presentNotification(title: .SentTab_TabArrivingNotification_NoDevice_title, body: url.absoluteDisplayExternalString)
        }
    }

    func presentNotification(title: String, body: String, titleArg: String? = nil, bodyArg: String? = nil) {
        func stringWithOptionalArg(_ s: String, _ a: String?) -> String {
            if let a = a {
                return String(format: s, a)
            }
            return s
        }

        notificationContent.title = stringWithOptionalArg(title, titleArg)
        notificationContent.body = stringWithOptionalArg(body, bodyArg)

        // This is the only place we call the contentHandler.
        contentHandler(notificationContent)
        // This is the only place we change messageDelivered. We can check if contentHandler hasn't be called because of
        // our logic (rather than something funny with our environment, or iOS killing us).
        messageDelivered = true
    }
}

struct SentTab {
    let url: URL
    let title: String
    let deviceName: String?
}
