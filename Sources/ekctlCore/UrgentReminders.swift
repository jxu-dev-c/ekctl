import Foundation
import ObjectiveC

/// Reads and writes the Reminders "Urgent" flag (macOS 26+), which makes a
/// reminder ring as a full-screen alarm at its due time instead of posting a
/// plain notification.
///
/// Public EventKit has no API for this, so the flag goes through Apple's
/// private ReminderKit framework, loaded at runtime with `dlopen` and driven
/// through the Objective-C runtime — there are no headers to compile against
/// and nothing to link. Every class and selector is checked before use, so on
/// an older macOS (or a future one that renames them) `isAvailable` is false
/// and callers report `urgent: null` instead of crashing.
///
/// EventKit's `calendarItemIdentifier` for a reminder is the same UUID
/// ReminderKit uses for its `REMCDReminder` object ID, which is how the two
/// worlds are joined.
public final class UrgentReminders {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static let unavailableMessage =
        "Urgent reminders require macOS 26 or later (ReminderKit urgent support not found)."

    /// The error message when `--urgent true` cannot apply, else nil. An urgent
    /// reminder rings at its due time, so one without a due date would never
    /// fire. Pure so it can be checked before the TCC prompt and unit-tested.
    public static func validate(urgent: Bool?, hasDueDate: Bool) -> String? {
        guard urgent == true, !hasDueDate else { return nil }
        return "Urgent reminders need a due date and time; pass --due."
    }

    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/ReminderKit.framework/ReminderKit"
    private static let urgentKey = "isUrgentStateEnabledForCurrentUser"

    private static let loaded: Bool = dlopen(frameworkPath, RTLD_LAZY) != nil

    public static var isAvailable: Bool {
        guard loaded,
            let store = NSClassFromString("REMStore") as? NSObject.Type,
            let reminder = NSClassFromString("REMReminder") as? NSObject.Type,
            let changeItem = NSClassFromString("REMReminderChangeItem") as? NSObject.Type,
            let saveRequest = NSClassFromString("REMSaveRequest") as? NSObject.Type,
            let objectID = NSClassFromString("REMObjectID") as? NSObject.Type
        else { return false }
        return store.instancesRespond(to: Selectors.fetchOne)
            && store.instancesRespond(to: Selectors.fetchMany)
            && reminder.instancesRespond(to: NSSelectorFromString("urgentAlarmContext"))
            // The change item's setter is @dynamic — resolved at runtime, so
            // `instancesRespond(to:)` misses it. Check the declared property.
            && class_getProperty(changeItem, urgentKey) != nil
            && saveRequest.instancesRespond(to: Selectors.initWithStore)
            && saveRequest.instancesRespond(to: Selectors.updateReminder)
            && saveRequest.instancesRespond(to: Selectors.save)
            && objectID.responds(to: Selectors.objectIDWithUUID)
    }

    private enum Selectors {
        static let fetchOne = NSSelectorFromString("fetchReminderWithObjectID:error:")
        static let fetchMany = NSSelectorFromString("fetchRemindersWithObjectIDs:error:")
        static let initWithStore = NSSelectorFromString("initWithStore:")
        static let updateReminder = NSSelectorFromString("updateReminder:")
        static let save = NSSelectorFromString("saveSynchronouslyWithError:")
        static let objectIDWithUUID = NSSelectorFromString("objectIDWithUUID:entityName:")
    }

    private typealias FetchOne = @convention(c) (
        AnyObject, Selector, AnyObject, UnsafeMutablePointer<NSError?>?
    ) -> AnyObject?
    private typealias FetchMany = @convention(c) (
        AnyObject, Selector, NSArray, UnsafeMutablePointer<NSError?>?
    ) -> AnyObject?
    private typealias Save = @convention(c) (
        AnyObject, Selector, UnsafeMutablePointer<NSError?>?
    ) -> Bool

    private let store: NSObject

    /// Returns nil when ReminderKit's urgent support is unavailable.
    public init?() {
        guard Self.isAvailable, let storeClass = NSClassFromString("REMStore") as? NSObject.Type
        else { return nil }
        store = storeClass.init()
    }

    /// Urgent state for each EventKit reminder ID, fetched in one round trip.
    /// IDs ReminderKit doesn't know are absent from the result.
    public func urgentStates(for reminderIDs: [String]) -> [String: Bool] {
        let objectIDs = reminderIDs.compactMap(Self.objectID)
        guard !objectIDs.isEmpty else { return [:] }
        let fetch = unsafeBitCast(store.method(for: Selectors.fetchMany), to: FetchMany.self)
        var error: NSError?
        guard let byID = fetch(store, Selectors.fetchMany, objectIDs as NSArray, &error)
            as? NSDictionary
        else { return [:] }

        var states: [String: Bool] = [:]
        for case let reminder as NSObject in byID.allValues {
            guard let objectID = reminder.value(forKey: "objectID") as? NSObject,
                let uuid = objectID.value(forKey: "uuid") as? UUID,
                let urgent = Self.urgentState(of: reminder)
            else { continue }
            states[uuid.uuidString] = urgent
        }
        return states
    }

    public func urgentState(for reminderID: String) -> Bool? {
        guard let reminder = try? fetch(reminderID) else { return nil }
        return Self.urgentState(of: reminder)
    }

    public func setUrgent(_ urgent: Bool, reminderID: String) throws {
        let reminder = try fetch(reminderID)
        guard let saveRequestClass = NSClassFromString("REMSaveRequest") as? NSObject.Type,
            let allocated = saveRequestClass.perform(NSSelectorFromString("alloc"))?
                .takeUnretainedValue() as? NSObject,
            let saveRequest = allocated.perform(Selectors.initWithStore, with: store)?
                .takeUnretainedValue() as? NSObject,
            let changeItem = saveRequest.perform(Selectors.updateReminder, with: reminder)?
                .takeUnretainedValue() as? NSObject
        else { throw Failure(description: "Could not prepare the Reminders save request.") }

        changeItem.setValue(urgent, forKey: Self.urgentKey)

        let save = unsafeBitCast(saveRequest.method(for: Selectors.save), to: Save.self)
        var error: NSError?
        guard save(saveRequest, Selectors.save, &error) else {
            throw Failure(
                description: "Reminders rejected the urgent change: "
                    + (error?.localizedDescription ?? "unknown error"))
        }
    }

    private func fetch(_ reminderID: String) throws -> NSObject {
        guard let objectID = Self.objectID(for: reminderID) else {
            throw Failure(description: "Reminder ID '\(reminderID)' is not a Reminders UUID.")
        }
        let fetch = unsafeBitCast(store.method(for: Selectors.fetchOne), to: FetchOne.self)
        var error: NSError?
        guard let reminder = fetch(store, Selectors.fetchOne, objectID, &error) as? NSObject
        else {
            throw Failure(description: "Reminder not found in Reminders with ID: \(reminderID)")
        }
        return reminder
    }

    private static func objectID(for reminderID: String) -> AnyObject? {
        guard let uuid = UUID(uuidString: reminderID),
            let objectIDClass = NSClassFromString("REMObjectID") as? NSObject.Type
        else { return nil }
        return objectIDClass.perform(
            Selectors.objectIDWithUUID, with: uuid as NSUUID, with: "REMCDReminder")?
            .takeUnretainedValue()
    }

    private static func urgentState(of reminder: NSObject) -> Bool? {
        (reminder.value(forKey: "urgentAlarmContext") as? NSObject)?
            .value(forKey: urgentKey) as? Bool
    }
}
