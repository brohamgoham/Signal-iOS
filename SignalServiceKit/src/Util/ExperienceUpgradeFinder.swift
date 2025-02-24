//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation
import Contacts

public enum ExperienceUpgradeId: String, CaseIterable, Dependencies {
    case introducingPins = "009"
    case pinReminder // Never saved, used to periodically prompt the user for their PIN
    case notificationPermissionReminder
    case contactPermissionReminder
    case linkPreviews
    case researchMegaphone1
    case groupsV2AndMentionsSplash2
    case groupCallsMegaphone
    case sharingSuggestions
    case donateMegaphone
    case chatColors
    case avatarBuilder

    // Until this flag is true the upgrade won't display to users.
    func hasLaunched(transaction: GRDBReadTransaction) -> Bool {
        AssertIsOnMainThread()

        if let registrationDate = tsAccountManager.registrationDate(with: transaction.asAnyRead) {
            guard Date().timeIntervalSince(registrationDate) >= delayAfterRegistration else {
                return false
            }
        }

        switch self {
        case .introducingPins:
            // The PIN setup flow requires an internet connection and you to not already have a PIN
            return RemoteConfig.kbs &&
                Self.reachabilityManager.isReachable &&
                !KeyBackupService.hasMasterKey(transaction: transaction.asAnyRead)
        case .pinReminder:
            return OWS2FAManager.shared.isDueForV2Reminder(transaction: transaction.asAnyRead)
        case .notificationPermissionReminder:
            let (promise, future) = Promise<Bool>.pending()

            Logger.info("Checking notification authorization")

            DispatchQueue.global(qos: .userInitiated).async {
                UNUserNotificationCenter.current().getNotificationSettings { settings in
                    Logger.info("Checked notification authorization \(settings.authorizationStatus)")
                    future.resolve(settings.authorizationStatus == .authorized)
                }
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) {
                guard promise.result == nil else { return }
                future.reject(OWSGenericError("timeout fetching notification permissions"))
            }

            do {
                return !(try promise.wait())
            } catch {
                Logger.warn("failed to query notification permission")
                return false
            }
        case .contactPermissionReminder:
            return CNContactStore.authorizationStatus(for: CNEntityType.contacts) != .authorized
        case .linkPreviews:
            return true
        case .researchMegaphone1:
            return RemoteConfig.researchMegaphone
        case .groupsV2AndMentionsSplash2:
            return FeatureFlags.groupsV2showSplash
        case .groupCallsMegaphone:
            return RemoteConfig.groupCalling
        case .sharingSuggestions:
            return true
        case .donateMegaphone:
            return RemoteConfig.donateMegaphone
        case .chatColors:
            return true
        case .avatarBuilder:
            return profileManager.localProfileAvatarData() == nil
        }
    }

    // Some upgrades stop running after a certain date. This lets
    // us know if we're still before that end date.
    var hasExpired: Bool {
        let expirationDate: TimeInterval

        switch self {
        default:
            expirationDate = Date.distantFuture.timeIntervalSince1970
        }

        return Date().timeIntervalSince1970 > expirationDate
    }

    // If false, this will not be marked complete after registration.
    var skipForNewUsers: Bool {
        switch self {
        case .introducingPins,
             .researchMegaphone1,
             .donateMegaphone:
            return false
        default:
            return true
        }
    }

    // This much time must have passed since the user registered
    // before the megaphone is ever presented.
    var delayAfterRegistration: TimeInterval {
        switch self {
        case .contactPermissionReminder,
             .notificationPermissionReminder:
            return kDayInterval
        case .introducingPins:
            // Create a PIN after KBS network failure
            return 2 * kHourInterval
        case .pinReminder:
            return 8 * kHourInterval
        case .donateMegaphone:
            return 5 * kDayInterval
        default:
            return 0
        }
    }

    // In addition to being sorted by their order as defined in this enum,
    // experience upgrades are also sorted by priority. For example, a high
    // priority upgrade will always show before a low priority experience
    // upgrade, even if it shows up later in the list.
    enum Priority: Int {
        case low
        case medium
        case high
    }
    var priority: Priority {
        switch self {
        case .introducingPins:
            return .high
        case .linkPreviews:
            return .medium
        case .pinReminder:
            return .medium
        case .notificationPermissionReminder:
            return .medium
        case .contactPermissionReminder:
            return .medium
        case .researchMegaphone1:
            return .low
        case .groupsV2AndMentionsSplash2:
            return .medium
        case .groupCallsMegaphone:
            return .medium
        case .sharingSuggestions:
            return .medium
        case .donateMegaphone:
            return .low
        case .chatColors:
            return .low
        case .avatarBuilder:
            return .medium
        }
    }

    // Some experience flows are dynamic and can be experience multiple
    // times so they don't need be saved to the database.
    var shouldSave: Bool {
        switch self {
        case .pinReminder:
            return false
        default:
            return true
        }
    }

    // Some experience upgrades are dynamic, but still track state (like
    // snooze duration), but can never be permanently completed.
    var canBeCompleted: Bool {
        switch self {
        case .pinReminder:
            return false
        case .notificationPermissionReminder:
            return false
        case .contactPermissionReminder:
            return false
        case .donateMegaphone:
            return false
        default:
            return true
        }
    }

    var snoozeDuration: TimeInterval {
        switch self {
        case .notificationPermissionReminder:
            return kDayInterval * 30
        case .contactPermissionReminder:
            return kDayInterval * 30
        case .donateMegaphone:
            return RemoteConfig.donateMegaphoneSnoozeInterval
        default:
            return kDayInterval * 2
        }
    }

    var showOnLinkedDevices: Bool {
        switch self {
        case .notificationPermissionReminder:
            return true
        case .contactPermissionReminder:
            return true
        case .sharingSuggestions:
            return true
        case .donateMegaphone:
            return true
        default:
            return false
        }
    }
}

@objc
public class ExperienceUpgradeFinder: NSObject {

    // MARK: -

    public class func next(transaction: GRDBReadTransaction) -> ExperienceUpgrade? {
        return allActiveExperienceUpgrades(transaction: transaction).first { !$0.isSnoozed }
    }

    public class func allIncomplete(transaction: GRDBReadTransaction) -> [ExperienceUpgrade] {
        return allActiveExperienceUpgrades(transaction: transaction).filter { !$0.isComplete }
    }

    public class func hasIncomplete(experienceUpgradeId: ExperienceUpgradeId, transaction: GRDBReadTransaction) -> Bool {
        return allIncomplete(transaction: transaction).contains { experienceUpgradeId.rawValue == $0.uniqueId }
    }

    public class func markAsViewed(experienceUpgrade: ExperienceUpgrade, transaction: GRDBWriteTransaction) {
        Logger.info("marking experience upgrade as seen \(experienceUpgrade.uniqueId)")
        experienceUpgrade.upsertWith(transaction: transaction.asAnyWrite) { experienceUpgrade in
            // Only mark as viewed if it has yet to be viewed.
            guard experienceUpgrade.firstViewedTimestamp == 0 else { return }
            experienceUpgrade.firstViewedTimestamp = Date().timeIntervalSince1970
        }
    }

    public class func hasUnsnoozed(experienceUpgradeId: ExperienceUpgradeId, transaction: GRDBReadTransaction) -> Bool {
        return allIncomplete(transaction: transaction).first { experienceUpgradeId.rawValue == $0.uniqueId }?.isSnoozed == false
    }

    public class func markAsSnoozed(experienceUpgradeId: ExperienceUpgradeId, transaction: GRDBWriteTransaction) {
        markAsSnoozed(experienceUpgrade: ExperienceUpgrade(uniqueId: experienceUpgradeId.rawValue), transaction: transaction)
    }

    public class func markAsSnoozed(experienceUpgrade: ExperienceUpgrade, transaction: GRDBWriteTransaction) {
        Logger.info("marking experience upgrade as snoozed \(experienceUpgrade.uniqueId)")
        experienceUpgrade.upsertWith(transaction: transaction.asAnyWrite) { $0.lastSnoozedTimestamp = Date().timeIntervalSince1970 }
    }

    public class func markAsComplete(experienceUpgradeId: ExperienceUpgradeId, transaction: GRDBWriteTransaction) {
        markAsComplete(experienceUpgrade: ExperienceUpgrade(uniqueId: experienceUpgradeId.rawValue), transaction: transaction)
    }

    public class func markAsComplete(experienceUpgrade: ExperienceUpgrade, transaction: GRDBWriteTransaction) {
        guard experienceUpgrade.id.canBeCompleted else {
            return Logger.info("skipping marking experience upgrade as complete for experience upgrade \(experienceUpgrade.uniqueId)")
        }

        Logger.info("marking experience upgrade as complete \(experienceUpgrade.uniqueId)")

        experienceUpgrade.upsertWith(transaction: transaction.asAnyWrite) { $0.isComplete = true }
    }

    @objc
    public class func markAllCompleteForNewUser(transaction: GRDBWriteTransaction) {
        ExperienceUpgradeId.allCases
            .filter { $0.skipForNewUsers }
            .forEach { markAsComplete(experienceUpgradeId: $0, transaction: transaction) }
    }

    // MARK: -

    /// Returns an array of all experience upgrades currently being run that have
    /// yet to be completed. Sorted by priority from highest to lowest. For equal
    /// priority upgrades follows the order of the `ExperienceUpgradeId` enumeration
    private class func allActiveExperienceUpgrades(transaction: GRDBReadTransaction) -> [ExperienceUpgrade] {
        let isPrimaryDevice = Self.tsAccountManager.isRegisteredPrimaryDevice

        let activeIds = ExperienceUpgradeId
            .allCases
            .filter { $0.hasLaunched(transaction: transaction) && !$0.hasExpired && ($0.showOnLinkedDevices || isPrimaryDevice) }
            .map { $0.rawValue }

        // We don't include `isComplete` in the query as we want to initialize
        // new records for any active ids that haven't had one recorded yet.
        let cursor = ExperienceUpgrade.grdbFetchCursor(
            sql: """
                SELECT * FROM \(ExperienceUpgradeRecord.databaseTableName)
                WHERE \(experienceUpgradeColumn: .uniqueId) IN (\(activeIds.map { "\'\($0)'" }.joined(separator: ",")))
            """,
            transaction: transaction
        )

        var experienceUpgrades = [ExperienceUpgrade]()
        var unsavedIds = activeIds

        while true {
            guard let experienceUpgrade = try? cursor.next() else { break }
            guard experienceUpgrade.id.shouldSave else {
                // Ignore saved upgrades that we don't currently save.
                continue
            }
            if !experienceUpgrade.isComplete && !experienceUpgrade.hasCompletedVisibleDuration {
                experienceUpgrades.append(experienceUpgrade)
            }

            unsavedIds.removeAll { $0 == experienceUpgrade.uniqueId }
        }

        for id in unsavedIds {
            experienceUpgrades.append(ExperienceUpgrade(uniqueId: id))
        }

        return experienceUpgrades.sorted { lhs, rhs in
            guard lhs.id.priority == rhs.id.priority else {
                return lhs.id.priority.rawValue > rhs.id.priority.rawValue
            }

            guard let lhsIndex = activeIds.firstIndex(of: lhs.uniqueId),
                let rhsIndex = activeIds.firstIndex(of: rhs.uniqueId) else {
                    owsFailDebug("failed to find index for uniqueIds \(lhs.uniqueId) \(rhs.uniqueId)")
                    return false
            }

            return lhsIndex < rhsIndex
        }
    }
}

public extension ExperienceUpgrade {
    var id: ExperienceUpgradeId! {
        return ExperienceUpgradeId(rawValue: uniqueId)
    }

    var isSnoozed: Bool {
        guard lastSnoozedTimestamp > 0 else { return false }
        // If it hasn't been two days since we were snoozed, wait to show again.
        return -Date(timeIntervalSince1970: lastSnoozedTimestamp).timeIntervalSinceNow <= id.snoozeDuration
    }

    var daysSinceFirstViewed: Int {
        guard firstViewedTimestamp > 0 else { return 0 }
        let secondsSinceFirstView = -Date(timeIntervalSince1970: firstViewedTimestamp).timeIntervalSinceNow
        return Int(secondsSinceFirstView / kDayInterval)
    }

    var hasCompletedVisibleDuration: Bool {
        switch id {
        case .researchMegaphone1: return daysSinceFirstViewed >= 7
        default: return false
        }
    }

    var hasViewed: Bool { firstViewedTimestamp > 0 }

    func upsertWith(transaction: SDSAnyWriteTransaction, changeBlock: (ExperienceUpgrade) -> Void) {
        guard id.shouldSave else { return Logger.debug("Skipping save for experience upgrade \(String(describing: id))") }

        let experienceUpgrade = ExperienceUpgrade.anyFetch(uniqueId: uniqueId, transaction: transaction) ?? self
        changeBlock(experienceUpgrade)
        experienceUpgrade.anyUpsert(transaction: transaction)
    }
}
