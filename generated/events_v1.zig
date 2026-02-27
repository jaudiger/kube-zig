// Auto-generated from Kubernetes OpenAPI spec.
// Do not edit manually. Regenerate with: zig build generate

const std = @import("std");
const json = std.json;
const core_v1 = @import("core_v1.zig");
const meta_v1 = @import("meta_v1.zig");

/// Event is a report of an event somewhere in the cluster. It generally denotes some state change in the system. Events have a limited retention time and triggers and messages may evolve with time.  Event consumers should not rely on the timing of an event with a given Reason reflecting a consistent underlying trigger, or the continued existence of events with that Reason.  Events should be treated as informative, best-effort, supplemental data.
pub const EventsV1Event = struct {
    pub const resource_meta = .{
        .group = "events.k8s.io",
        .version = "v1",
        .kind = "Event",
        .resource = "events",
        .namespaced = true,
        .list_kind = EventsV1EventList,
    };

    /// action is what action was taken/failed regarding to the regarding object. It is machine-readable. This field cannot be empty for new Events and it can have at most 128 characters.
    action: ?[]const u8 = null,
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// deprecatedCount is the deprecated field assuring backward compatibility with core.v1 Event type.
    deprecatedCount: ?i32 = null,
    /// deprecatedFirstTimestamp is the deprecated field assuring backward compatibility with core.v1 Event type.
    deprecatedFirstTimestamp: ?meta_v1.MetaV1Time = null,
    /// deprecatedLastTimestamp is the deprecated field assuring backward compatibility with core.v1 Event type.
    deprecatedLastTimestamp: ?meta_v1.MetaV1Time = null,
    /// deprecatedSource is the deprecated field assuring backward compatibility with core.v1 Event type.
    deprecatedSource: ?core_v1.CoreV1EventSource = null,
    /// eventTime is the time when this Event was first observed. It is required.
    eventTime: meta_v1.MetaV1MicroTime,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard object's metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ObjectMeta = null,
    /// note is a human-readable description of the status of this operation. Maximal length of the note is 1kB, but libraries should be prepared to handle values up to 64kB.
    note: ?[]const u8 = null,
    /// reason is why the action was taken. It is human-readable. This field cannot be empty for new Events and it can have at most 128 characters.
    reason: ?[]const u8 = null,
    /// regarding contains the object this Event is about. In most cases it's an Object reporting controller implements, e.g. ReplicaSetController implements ReplicaSets and this event is emitted because it acts on some changes in a ReplicaSet object.
    regarding: ?core_v1.CoreV1ObjectReference = null,
    /// related is the optional secondary object for more complex actions. E.g. when regarding object triggers a creation or deletion of related object.
    related: ?core_v1.CoreV1ObjectReference = null,
    /// reportingController is the name of the controller that emitted this Event, e.g. `kubernetes.io/kubelet`. This field cannot be empty for new Events.
    reportingController: ?[]const u8 = null,
    /// reportingInstance is the ID of the controller instance, e.g. `kubelet-xyzf`. This field cannot be empty for new Events and it can have at most 128 characters.
    reportingInstance: ?[]const u8 = null,
    /// series is data about the Event series this event represents or nil if it's a singleton Event.
    series: ?EventsV1EventSeries = null,
    /// type is the type of this event (Normal, Warning), new types could be added in the future. It is machine-readable. This field cannot be empty for new Events.
    type: ?[]const u8 = null,
};

/// EventList is a list of Event objects.
pub const EventsV1EventList = struct {
    /// APIVersion defines the versioned schema of this representation of an object. Servers should convert recognized schemas to the latest internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources
    apiVersion: ?[]const u8 = null,
    /// items is a list of schema objects.
    items: []const EventsV1Event,
    /// Kind is a string value representing the REST resource this object represents. Servers may infer this from the endpoint the client submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds
    kind: ?[]const u8 = null,
    /// Standard list metadata. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#metadata
    metadata: ?meta_v1.MetaV1ListMeta = null,
};

/// EventSeries contain information on series of events, i.e. thing that was/is happening continuously for some time. How often to update the EventSeries is up to the event reporters. The default event reporter in "k8s.io/client-go/tools/events/event_broadcaster.go" shows how this struct is updated on heartbeats and can guide customized reporter implementations.
pub const EventsV1EventSeries = struct {
    /// count is the number of occurrences in this series up to the last heartbeat time.
    count: i32,
    /// lastObservedTime is the time when last Event from the series was seen before last heartbeat.
    lastObservedTime: meta_v1.MetaV1MicroTime,
};
