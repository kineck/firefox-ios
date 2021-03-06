/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Account
import Deferred
import Foundation
import Shared
import SwiftyJSON
import Sync
import UserNotifications
import XCGLogger

private let applicationDidRequestUserNotificationPermissionPrefKey = "applicationDidRequestUserNotificationPermissionPrefKey"

private let log = Logger.browserLogger

private let verificationPollingInterval = DispatchTimeInterval.seconds(3)
private let verificationMaxRetries = 100 // Poll every 3 seconds for 5 minutes.

protocol FxAPushLoginDelegate : class {
    func accountLoginDidFail()

    func accountLoginDidSucceed(withFlags flags: FxALoginFlags)
}

/// Small struct to keep together the immediately actionable flags that the UI is likely to immediately
/// following a successful login. This is not supposed to be a long lived object.
struct FxALoginFlags {
    let pushEnabled: Bool
    let verified: Bool
}

/// This class manages the from successful login for FxAccounts to 
/// asking the user for notification permissions, registering for 
/// remote push notifications (APNS), then creating an account and 
/// storing it in the profile.
class FxALoginHelper {
    static var sharedInstance: FxALoginHelper = {
        return FxALoginHelper()
    }()

    weak var delegate: FxAPushLoginDelegate?

    fileprivate weak var profile: Profile?

    fileprivate var account: FirefoxAccount!

    fileprivate var accountVerified: Bool!

    // This should be called when the application has started.
    // This configures the helper for logging into Firefox Accounts, and
    // if already logged in, checking if anything needs to be done in response
    // to changing of user settings and push notifications.
    func application(_ application: UIApplication, didLoadProfile profile: Profile) {
        self.profile = profile
        self.account = profile.getAccount()

        guard let account = self.account else {
            // There's no account, no further action.
            return loginDidFail()
        }

        // accountVerified is needed by delegates.
        accountVerified = account.actionNeeded != .needsVerification

        // We should check if deviceRegistration has been performed, and 
        // update the sync scratch pad (a proxy for our client record) accordingly.
        // We do this here because this is effectively the upgrade path between 7 and 8.
        updateSyncScratchpad()

        guard AppConstants.MOZ_FXA_PUSH else {
            return loginDidSucceed()
        }

        if let _ = account.pushRegistration {
            // We have an account, and it's already registered for push notifications.
            return loginDidSucceed()
        }

        // Now: we have an account that does not have push notifications set up.
        // however, we need to deal with cases of asking for permissions too frequently.
        let asked = profile.prefs.boolForKey(applicationDidRequestUserNotificationPermissionPrefKey) ?? true
        let permitted = application.currentUserNotificationSettings!.types != .none

        // If we've never asked(*), then we should probably ask.
        // If we've asked already, then we should not ask again.
        // TODO: add UI to tell the user to go flip the Setting app.
        // (*) if we asked in a prior release, and the user was ok with it, then there is no harm asking again.
        // If the user denied permission, or flipped permissions in the Settings app, then 
        // we'll bug them once, but this is probably unavoidable.
        if asked && !permitted {
            return loginDidSucceed()
        }

        // By the time we reach here, we haven't registered for APNS
        // Either we've never asked the user, or the user declined, then re-enabled
        // the notification in the Settings app.
        requestUserNotifications(application)
    }

    // This is called when the user logs into a new FxA account.
    // It manages the asking for user permission for notification and registration 
    // for APNS and WebPush notifications.
    func application(_ application: UIApplication, didReceiveAccountJSON data: JSON) {
        if data["keyFetchToken"].stringValue() == nil || data["unwrapBKey"].stringValue() == nil {
            // The /settings endpoint sends a partial "login"; ignore it entirely.
            log.error("Ignoring didSignIn with keyFetchToken or unwrapBKey missing.")
            return self.loginDidFail()
        }

        assert(profile != nil, "Profile should still exist and be loaded into this FxAPushLoginStateMachine")

        guard let profile = profile,
            let account = FirefoxAccount.from(profile.accountConfiguration, andJSON: data) else {
                return self.loginDidFail()
        }
        accountVerified = data["verified"].bool ?? false
        self.account = account
        requestUserNotifications(application)
    }

    fileprivate func requestUserNotifications(_ application: UIApplication) {
        DispatchQueue.main.async {
            self.requestUserNotificationsMainThreadOnly(application)
        }
    }

    fileprivate func requestUserNotificationsMainThreadOnly(_ application: UIApplication) {
        assert(Thread.isMainThread, "requestAuthorization should be run on the main thread")
        if #available(iOS 10, *) {
            let center = UNUserNotificationCenter.current()
            return center.requestAuthorization(options: [.alert, .badge, .sound]) { (granted, error) in
                guard error == nil else {
                    return self.application(application, canDisplayUserNotifications: false)
                }
                self.application(application, canDisplayUserNotifications: granted)
            }
        }

        // This is for iOS 9 and below.
        // We'll still be using local notifications, i.e. the old behavior,
        // so we need to keep doing it like this.
        let viewAction = UIMutableUserNotificationAction()
        viewAction.identifier = SentTabAction.view.rawValue
        viewAction.title = Strings.SentTabViewActionTitle
        viewAction.activationMode = .foreground
        viewAction.isDestructive = false
        viewAction.isAuthenticationRequired = false

        let bookmarkAction = UIMutableUserNotificationAction()
        bookmarkAction.identifier = SentTabAction.bookmark.rawValue
        bookmarkAction.title = Strings.SentTabBookmarkActionTitle
        bookmarkAction.activationMode = .foreground
        bookmarkAction.isDestructive = false
        bookmarkAction.isAuthenticationRequired = false

        let readingListAction = UIMutableUserNotificationAction()
        readingListAction.identifier = SentTabAction.readingList.rawValue
        readingListAction.title = Strings.SentTabAddToReadingListActionTitle
        readingListAction.activationMode = .foreground
        readingListAction.isDestructive = false
        readingListAction.isAuthenticationRequired = false

        let sentTabsCategory = UIMutableUserNotificationCategory()
        sentTabsCategory.identifier = TabSendCategory
        sentTabsCategory.setActions([readingListAction, bookmarkAction, viewAction], for: .default)

        sentTabsCategory.setActions([bookmarkAction, viewAction], for: .minimal)

        let settings = UIUserNotificationSettings(types: .alert, categories: [sentTabsCategory])

        application.registerUserNotificationSettings(settings)
    }

    // This is necessarily called from the AppDelegate.
    // Once we have permission from the user to display notifications, we should 
    // try and register for APNS. If not, then start syncing.
    func application(_ application: UIApplication, didRegisterUserNotificationSettings notificationSettings: UIUserNotificationSettings) {
        let types = notificationSettings.types
        let allowed = types != .none && types.rawValue != 0
        self.application(application, canDisplayUserNotifications: allowed)
    }

    func application(_ application: UIApplication, canDisplayUserNotifications allowed: Bool) {
        guard allowed else {
            return readyForSyncing()
        }

        // Record that we have asked the user, and they have given an answer.
        profile?.prefs.setBool(true, forKey: applicationDidRequestUserNotificationPermissionPrefKey)

        guard #available(iOS 10, *) else {
            return readyForSyncing()
        }

        if AppConstants.MOZ_FXA_PUSH {
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        } else {
            readyForSyncing()
        }
    }

    func getPushConfiguration() -> PushConfiguration? {
        let label = PushConfigurationLabel(rawValue: AppConstants.scheme)
        return label?.toConfiguration()
    }

    func apnsRegisterDidSucceed(_ deviceToken: Data) {
        let apnsToken = deviceToken.hexEncodedString

        guard let pushConfiguration = getPushConfiguration() ?? self.profile?.accountConfiguration.pushConfiguration,
            let accountConfiguration = profile?.accountConfiguration else {
            log.error("Push server endpoint could not be found")
            return pushRegistrationDidFail()
        }

        // Experimental mode needs: a) the scheme to be Fennec, and b) the accountConfiguration to be flipped in debug mode.
        let experimentalMode = (pushConfiguration.label == .fennec && accountConfiguration.label == .latestDev)
        let client = PushClient(endpointURL: pushConfiguration.endpointURL, experimentalMode: experimentalMode)
        client.register(apnsToken).upon { res in
            guard let pushRegistration = res.successValue else {
                return self.pushRegistrationDidFail()
            }
            return self.pushRegistrationDidSucceed(apnsToken: apnsToken, pushRegistration: pushRegistration)
        }
    }

    func apnsRegisterDidFail() {
        readyForSyncing()
    }

    fileprivate func pushRegistrationDidSucceed(apnsToken: String, pushRegistration: PushRegistration) {
        account.pushRegistration = pushRegistration
        readyForSyncing()
    }

    fileprivate func pushRegistrationDidFail() {
        readyForSyncing()
    }

    fileprivate func readyForSyncing() {
        guard let profile = self.profile, let account = self.account else {
            return loginDidSucceed()
        }

        profile.setAccount(account)

        awaitVerification()
        loginDidSucceed()
    }

    fileprivate func awaitVerification(_ attemptsLeft: Int = verificationMaxRetries) {
        guard let account = account,
            let profile = profile else {
            return
        }

        if attemptsLeft == 0 {
            return
        }

        // The only way we can tell if the account has been verified is to 
        // start a sync. If it works, then yay,
        account.advance().upon { state in
            if attemptsLeft == verificationMaxRetries {
                self.updateSyncScratchpad()
            }

            guard state.actionNeeded == .needsVerification else {
                // Verification has occurred remotely, and we can proceed.
                // The state machine will have told any listening UIs that 
                // we're done.
                return self.performVerifiedSync(profile, account: account)
            }

            if account.pushRegistration != nil {
                // Verification hasn't occurred yet, but we've registered for push 
                // so we can wait for a push notification in FxAPushMessageHandler.
                return
            }

            let queue = DispatchQueue.global(qos: DispatchQoS.background.qosClass)
            queue.asyncAfter(deadline: DispatchTime.now() + verificationPollingInterval) {
                self.awaitVerification(attemptsLeft - 1)
            }
        }
    }

    fileprivate func loginDidSucceed() {
        let flags = FxALoginFlags(pushEnabled: account?.pushRegistration != nil, verified: accountVerified)
        delegate?.accountLoginDidSucceed(withFlags: flags)
    }

    fileprivate func loginDidFail() {
        delegate?.accountLoginDidFail()
    }

    fileprivate func updateSyncScratchpad() {
        // We need to associate the fxaDeviceId with sync;
        // We can do this anything after the first time we account.advance()
        // but before the first time we sync.
        if let deviceRegistration = account?.deviceRegistration,
            let scratchpadPrefs = profile?.prefs.branch("sync.scratchpad") {
            scratchpadPrefs.setString(deviceRegistration.toJSON().stringValue()!, forKey: PrefDeviceRegistration)
        }
    }

    func performVerifiedSync(_ profile: Profile, account: FirefoxAccount) {
        profile.syncManager.syncEverything(why: .didLogin)
    }
}
