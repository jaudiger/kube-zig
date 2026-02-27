//! Vtable-based metrics abstractions for observability instrumentation.
//!
//! Defines the three standard metric primitives (Counter, Gauge, Histogram) and
//! per-subsystem metric bundles (client, queue, reconciler, informer, leader).
//! Each subsystem has a Factory vtable that backends (Prometheus, StatsD, etc.)
//! implement. All types provide a zero-cost `noop` default that discards updates.

const std = @import("std");
const testing = std.testing;

/// A monotonically increasing counter (e.g. total requests, total errors).
pub const Counter = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    /// VTable for counter implementations.
    pub const VTable = struct {
        inc: *const fn (ptr: ?*anyopaque) void,
        add: *const fn (ptr: ?*anyopaque, value: f64) void,
    };

    /// Increment the counter by one.
    pub fn inc(self: Counter) void {
        self.vtable.inc(self.ptr);
    }

    /// Add the given non-negative value to the counter.
    pub fn add(self: Counter, value: f64) void {
        self.vtable.add(self.ptr, value);
    }

    /// No-op counter that discards all updates.
    pub const noop: Counter = .{ .ptr = null, .vtable = &noop_vtable };
    fn noopInc(_: ?*anyopaque) void {}
    fn noopAdd(_: ?*anyopaque, _: f64) void {}
    const noop_vtable: VTable = .{ .inc = noopInc, .add = noopAdd };
};

/// A value that can go up and down (e.g. queue depth, active workers).
pub const Gauge = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    /// VTable for gauge implementations.
    pub const VTable = struct {
        set: *const fn (ptr: ?*anyopaque, value: f64) void,
        inc: *const fn (ptr: ?*anyopaque) void,
        dec: *const fn (ptr: ?*anyopaque) void,
    };

    /// Set the gauge to an absolute value.
    pub fn set(self: Gauge, value: f64) void {
        self.vtable.set(self.ptr, value);
    }

    /// Increment the gauge by one.
    pub fn inc(self: Gauge) void {
        self.vtable.inc(self.ptr);
    }

    /// Decrement the gauge by one.
    pub fn dec(self: Gauge) void {
        self.vtable.dec(self.ptr);
    }

    /// No-op gauge that discards all updates.
    pub const noop: Gauge = .{ .ptr = null, .vtable = &noop_vtable };
    fn noopSet(_: ?*anyopaque, _: f64) void {}
    fn noopInc(_: ?*anyopaque) void {}
    fn noopDec(_: ?*anyopaque) void {}
    const noop_vtable: VTable = .{ .set = noopSet, .inc = noopInc, .dec = noopDec };
};

/// Records distributions of values (e.g. request latency, reconcile duration).
pub const Histogram = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    /// VTable for histogram implementations.
    pub const VTable = struct {
        observe: *const fn (ptr: ?*anyopaque, value: f64) void,
    };

    /// Record a single observation (e.g. a latency measurement in seconds).
    pub fn observe(self: Histogram, value: f64) void {
        self.vtable.observe(self.ptr, value);
    }

    /// No-op histogram that discards all observations.
    pub const noop: Histogram = .{ .ptr = null, .vtable = &noop_vtable };
    fn noopObserve(_: ?*anyopaque, _: f64) void {}
    const noop_vtable: VTable = .{ .observe = noopObserve };
};

/// Aggregate of per-domain metric factories.
///
/// Users implement individual domain factories to bridge to their metrics
/// backend (Prometheus, StatsD, in-memory, etc.). Each domain factory has
/// its own small vtable, so adding a new metric domain does not require
/// modifying unrelated factories.
pub const MetricsProvider = struct {
    client: ClientMetrics.Factory = ClientMetrics.Factory.noop,
    queue: QueueMetrics.Factory = QueueMetrics.Factory.noop,
    reconciler: ReconcilerMetrics.Factory = ReconcilerMetrics.Factory.noop,
    informer: InformerMetrics.Factory = InformerMetrics.Factory.noop,
    leader: LeaderMetrics.Factory = LeaderMetrics.Factory.noop,

    /// No-op provider where every factory produces no-op metrics. Zero cost.
    pub const noop: MetricsProvider = .{};
};

// Per-subsystem metrics structs
/// Metrics for the HTTP client layer.
pub const ClientMetrics = struct {
    request_total: Counter,
    request_latency: Histogram,
    request_error_total: Counter,
    retry_total: Counter,
    rate_limiter_latency: Histogram,
    circuit_breaker_state: Gauge,
    circuit_breaker_trip_total: Counter,
    pool_size: Gauge,
    pool_idle_connections: Gauge,
    pool_active_connections: Gauge,

    pub const noop: ClientMetrics = .{
        .request_total = Counter.noop,
        .request_latency = Histogram.noop,
        .request_error_total = Counter.noop,
        .retry_total = Counter.noop,
        .rate_limiter_latency = Histogram.noop,
        .circuit_breaker_state = Gauge.noop,
        .circuit_breaker_trip_total = Counter.noop,
        .pool_size = Gauge.noop,
        .pool_idle_connections = Gauge.noop,
        .pool_active_connections = Gauge.noop,
    };

    /// Factory that creates `ClientMetrics` instances.
    /// HTTP client metrics are singleton (no name label).
    pub const Factory = struct {
        ptr: ?*anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            new_request_total: *const fn (ptr: ?*anyopaque) Counter,
            new_request_latency: *const fn (ptr: ?*anyopaque) Histogram,
            new_request_error_total: *const fn (ptr: ?*anyopaque) Counter,
            new_retry_total: *const fn (ptr: ?*anyopaque) Counter,
            new_rate_limiter_latency: *const fn (ptr: ?*anyopaque) Histogram,
            new_circuit_breaker_state: *const fn (ptr: ?*anyopaque) Gauge,
            new_circuit_breaker_trip_total: *const fn (ptr: ?*anyopaque) Counter,
            new_pool_size: *const fn (ptr: ?*anyopaque) Gauge = noopGauge,
            new_pool_idle_connections: *const fn (ptr: ?*anyopaque) Gauge = noopGauge,
            new_pool_active_connections: *const fn (ptr: ?*anyopaque) Gauge = noopGauge,
        };

        pub const noop: Factory = .{ .ptr = null, .vtable = &noop_vtable };

        fn noopCounter(_: ?*anyopaque) Counter {
            return Counter.noop;
        }
        fn noopHistogram(_: ?*anyopaque) Histogram {
            return Histogram.noop;
        }
        fn noopGauge(_: ?*anyopaque) Gauge {
            return Gauge.noop;
        }

        const noop_vtable: VTable = .{
            .new_request_total = noopCounter,
            .new_request_latency = noopHistogram,
            .new_request_error_total = noopCounter,
            .new_retry_total = noopCounter,
            .new_rate_limiter_latency = noopHistogram,
            .new_circuit_breaker_state = noopGauge,
            .new_circuit_breaker_trip_total = noopCounter,
        };

        /// Create a new `ClientMetrics` instance by calling each vtable constructor.
        pub fn create(self: Factory) ClientMetrics {
            return .{
                .request_total = self.vtable.new_request_total(self.ptr),
                .request_latency = self.vtable.new_request_latency(self.ptr),
                .request_error_total = self.vtable.new_request_error_total(self.ptr),
                .retry_total = self.vtable.new_retry_total(self.ptr),
                .rate_limiter_latency = self.vtable.new_rate_limiter_latency(self.ptr),
                .circuit_breaker_state = self.vtable.new_circuit_breaker_state(self.ptr),
                .circuit_breaker_trip_total = self.vtable.new_circuit_breaker_trip_total(self.ptr),
                .pool_size = self.vtable.new_pool_size(self.ptr),
                .pool_idle_connections = self.vtable.new_pool_idle_connections(self.ptr),
                .pool_active_connections = self.vtable.new_pool_active_connections(self.ptr),
            };
        }
    };
};

/// Metrics for a work queue instance.
pub const QueueMetrics = struct {
    depth: Gauge,
    adds_total: Counter,
    queue_latency: Histogram,
    work_duration: Histogram,
    retries_total: Counter,
    longest_running: Gauge,

    pub const noop: QueueMetrics = .{
        .depth = Gauge.noop,
        .adds_total = Counter.noop,
        .queue_latency = Histogram.noop,
        .work_duration = Histogram.noop,
        .retries_total = Counter.noop,
        .longest_running = Gauge.noop,
    };

    /// Factory that creates `QueueMetrics` instances.
    /// Queue metrics are per-controller (named).
    pub const Factory = struct {
        ptr: ?*anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            new_queue_depth: *const fn (ptr: ?*anyopaque, name: []const u8) Gauge,
            new_queue_adds_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_queue_latency: *const fn (ptr: ?*anyopaque, name: []const u8) Histogram,
            new_queue_work_duration: *const fn (ptr: ?*anyopaque, name: []const u8) Histogram,
            new_queue_retries_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_queue_longest_running: *const fn (ptr: ?*anyopaque, name: []const u8) Gauge,
        };

        pub const noop: Factory = .{ .ptr = null, .vtable = &noop_vtable };

        fn noopCounter(_: ?*anyopaque, _: []const u8) Counter {
            return Counter.noop;
        }
        fn noopHistogram(_: ?*anyopaque, _: []const u8) Histogram {
            return Histogram.noop;
        }
        fn noopGauge(_: ?*anyopaque, _: []const u8) Gauge {
            return Gauge.noop;
        }

        const noop_vtable: VTable = .{
            .new_queue_depth = noopGauge,
            .new_queue_adds_total = noopCounter,
            .new_queue_latency = noopHistogram,
            .new_queue_work_duration = noopHistogram,
            .new_queue_retries_total = noopCounter,
            .new_queue_longest_running = noopGauge,
        };

        /// Create a new `QueueMetrics` instance for the given controller name.
        pub fn create(self: Factory, name: []const u8) QueueMetrics {
            return .{
                .depth = self.vtable.new_queue_depth(self.ptr, name),
                .adds_total = self.vtable.new_queue_adds_total(self.ptr, name),
                .queue_latency = self.vtable.new_queue_latency(self.ptr, name),
                .work_duration = self.vtable.new_queue_work_duration(self.ptr, name),
                .retries_total = self.vtable.new_queue_retries_total(self.ptr, name),
                .longest_running = self.vtable.new_queue_longest_running(self.ptr, name),
            };
        }
    };
};

/// Metrics for a reconciler instance.
pub const ReconcilerMetrics = struct {
    reconcile_total: Counter,
    reconcile_errors_total: Counter,
    reconcile_duration: Histogram,
    active_workers: Gauge,

    pub const noop: ReconcilerMetrics = .{
        .reconcile_total = Counter.noop,
        .reconcile_errors_total = Counter.noop,
        .reconcile_duration = Histogram.noop,
        .active_workers = Gauge.noop,
    };

    /// Factory that creates `ReconcilerMetrics` instances.
    /// Reconciler metrics are per-controller (named).
    pub const Factory = struct {
        ptr: ?*anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            new_reconcile_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_reconcile_errors_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_reconcile_duration: *const fn (ptr: ?*anyopaque, name: []const u8) Histogram,
            new_active_workers: *const fn (ptr: ?*anyopaque, name: []const u8) Gauge,
        };

        pub const noop: Factory = .{ .ptr = null, .vtable = &noop_vtable };

        fn noopCounter(_: ?*anyopaque, _: []const u8) Counter {
            return Counter.noop;
        }
        fn noopHistogram(_: ?*anyopaque, _: []const u8) Histogram {
            return Histogram.noop;
        }
        fn noopGauge(_: ?*anyopaque, _: []const u8) Gauge {
            return Gauge.noop;
        }

        const noop_vtable: VTable = .{
            .new_reconcile_total = noopCounter,
            .new_reconcile_errors_total = noopCounter,
            .new_reconcile_duration = noopHistogram,
            .new_active_workers = noopGauge,
        };

        /// Create a new `ReconcilerMetrics` instance for the given controller name.
        pub fn create(self: Factory, name: []const u8) ReconcilerMetrics {
            return .{
                .reconcile_total = self.vtable.new_reconcile_total(self.ptr, name),
                .reconcile_errors_total = self.vtable.new_reconcile_errors_total(self.ptr, name),
                .reconcile_duration = self.vtable.new_reconcile_duration(self.ptr, name),
                .active_workers = self.vtable.new_active_workers(self.ptr, name),
            };
        }
    };
};

/// Metrics for an informer/reflector instance.
pub const InformerMetrics = struct {
    watch_events_total: Counter,
    watch_restarts_total: Counter,
    list_duration: Histogram,
    store_object_count: Gauge,
    initial_list_synced: Gauge,

    pub const noop: InformerMetrics = .{
        .watch_events_total = Counter.noop,
        .watch_restarts_total = Counter.noop,
        .list_duration = Histogram.noop,
        .store_object_count = Gauge.noop,
        .initial_list_synced = Gauge.noop,
    };

    /// Factory that creates `InformerMetrics` instances.
    /// Informer metrics are per-controller (named).
    pub const Factory = struct {
        ptr: ?*anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            new_watch_events_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_watch_restarts_total: *const fn (ptr: ?*anyopaque, name: []const u8) Counter,
            new_list_duration: *const fn (ptr: ?*anyopaque, name: []const u8) Histogram,
            new_store_object_count: *const fn (ptr: ?*anyopaque, name: []const u8) Gauge,
            new_initial_list_synced: *const fn (ptr: ?*anyopaque, name: []const u8) Gauge,
        };

        pub const noop: Factory = .{ .ptr = null, .vtable = &noop_vtable };

        fn noopCounter(_: ?*anyopaque, _: []const u8) Counter {
            return Counter.noop;
        }
        fn noopHistogram(_: ?*anyopaque, _: []const u8) Histogram {
            return Histogram.noop;
        }
        fn noopGauge(_: ?*anyopaque, _: []const u8) Gauge {
            return Gauge.noop;
        }

        const noop_vtable: VTable = .{
            .new_watch_events_total = noopCounter,
            .new_watch_restarts_total = noopCounter,
            .new_list_duration = noopHistogram,
            .new_store_object_count = noopGauge,
            .new_initial_list_synced = noopGauge,
        };

        /// Create a new `InformerMetrics` instance for the given controller name.
        pub fn create(self: Factory, name: []const u8) InformerMetrics {
            return .{
                .watch_events_total = self.vtable.new_watch_events_total(self.ptr, name),
                .watch_restarts_total = self.vtable.new_watch_restarts_total(self.ptr, name),
                .list_duration = self.vtable.new_list_duration(self.ptr, name),
                .store_object_count = self.vtable.new_store_object_count(self.ptr, name),
                .initial_list_synced = self.vtable.new_initial_list_synced(self.ptr, name),
            };
        }
    };
};

/// Metrics for leader election.
pub const LeaderMetrics = struct {
    is_leader: Gauge,
    transitions_total: Counter,

    pub const noop: LeaderMetrics = .{
        .is_leader = Gauge.noop,
        .transitions_total = Counter.noop,
    };

    /// Factory that creates `LeaderMetrics` instances.
    /// Leader election metrics are singleton (no name label).
    pub const Factory = struct {
        ptr: ?*anyopaque,
        vtable: *const VTable,

        pub const VTable = struct {
            new_leader_is_leader: *const fn (ptr: ?*anyopaque) Gauge,
            new_leader_transitions_total: *const fn (ptr: ?*anyopaque) Counter,
        };

        pub const noop: Factory = .{ .ptr = null, .vtable = &noop_vtable };

        fn noopGauge(_: ?*anyopaque) Gauge {
            return Gauge.noop;
        }
        fn noopCounter(_: ?*anyopaque) Counter {
            return Counter.noop;
        }

        const noop_vtable: VTable = .{
            .new_leader_is_leader = noopGauge,
            .new_leader_transitions_total = noopCounter,
        };

        /// Create a new `LeaderMetrics` instance by calling each vtable constructor.
        pub fn create(self: Factory) LeaderMetrics {
            return .{
                .is_leader = self.vtable.new_leader_is_leader(self.ptr),
                .transitions_total = self.vtable.new_leader_transitions_total(self.ptr),
            };
        }
    };
};

test "Counter.noop does not panic" {
    // Act / Assert
    Counter.noop.inc();
    Counter.noop.add(42.0);
}

test "Gauge.noop does not panic" {
    // Act / Assert
    Gauge.noop.set(1.0);
    Gauge.noop.inc();
    Gauge.noop.dec();
}

test "Histogram.noop does not panic" {
    // Act / Assert
    Histogram.noop.observe(0.5);
}

test "ClientMetrics.noop all fields are noop" {
    // Act / Assert
    const m = ClientMetrics.noop;
    m.request_total.inc();
    m.request_latency.observe(1.0);
    m.request_error_total.inc();
    m.retry_total.inc();
    m.rate_limiter_latency.observe(0.5);
    m.circuit_breaker_state.set(0.0);
    m.circuit_breaker_trip_total.inc();
    m.pool_size.set(10.0);
    m.pool_idle_connections.set(5.0);
    m.pool_active_connections.set(3.0);
}

test "QueueMetrics.noop all fields are noop" {
    // Act / Assert
    const m = QueueMetrics.noop;
    m.depth.set(0.0);
    m.adds_total.inc();
    m.queue_latency.observe(0.1);
    m.work_duration.observe(0.2);
    m.retries_total.inc();
    m.longest_running.set(0.0);
}

test "ReconcilerMetrics.noop all fields are noop" {
    // Act / Assert
    const m = ReconcilerMetrics.noop;
    m.reconcile_total.inc();
    m.reconcile_errors_total.inc();
    m.reconcile_duration.observe(0.3);
    m.active_workers.inc();
    m.active_workers.dec();
}

test "InformerMetrics.noop all fields are noop" {
    // Act / Assert
    const m = InformerMetrics.noop;
    m.watch_events_total.inc();
    m.watch_restarts_total.inc();
    m.list_duration.observe(1.5);
    m.store_object_count.set(10.0);
    m.initial_list_synced.set(1.0);
}

test "LeaderMetrics.noop all fields are noop" {
    // Act / Assert
    const m = LeaderMetrics.noop;
    m.is_leader.set(1.0);
    m.transitions_total.inc();
}

test "ClientMetrics.Factory.noop creates noop metrics" {
    // Act
    const m = ClientMetrics.Factory.noop.create();

    // Assert
    m.request_total.inc();
    m.request_latency.observe(0.1);
    m.request_error_total.inc();
    m.retry_total.inc();
    m.rate_limiter_latency.observe(0.5);
    m.circuit_breaker_state.set(0.0);
    m.circuit_breaker_trip_total.inc();
    m.pool_size.set(10.0);
    m.pool_idle_connections.set(5.0);
    m.pool_active_connections.set(3.0);
}

test "QueueMetrics.Factory.noop creates noop metrics" {
    // Act
    const m = QueueMetrics.Factory.noop.create("test");

    // Assert
    m.depth.set(1.0);
    m.adds_total.inc();
    m.queue_latency.observe(0.1);
    m.work_duration.observe(0.2);
    m.retries_total.inc();
    m.longest_running.set(0.0);
}

test "ReconcilerMetrics.Factory.noop creates noop metrics" {
    // Act
    const m = ReconcilerMetrics.Factory.noop.create("test");

    // Assert
    m.reconcile_total.inc();
    m.reconcile_errors_total.inc();
    m.reconcile_duration.observe(0.3);
    m.active_workers.inc();
}

test "InformerMetrics.Factory.noop creates noop metrics" {
    // Act
    const m = InformerMetrics.Factory.noop.create("test");

    // Assert
    m.watch_events_total.inc();
    m.watch_restarts_total.inc();
    m.list_duration.observe(1.5);
    m.store_object_count.set(10.0);
    m.initial_list_synced.set(1.0);
}

test "LeaderMetrics.Factory.noop creates noop metrics" {
    // Act
    const m = LeaderMetrics.Factory.noop.create();

    // Assert
    m.is_leader.set(1.0);
    m.transitions_total.inc();
}

test "MetricsProvider.noop has all noop factories" {
    // Arrange
    const p = MetricsProvider.noop;

    // Act
    const client_m = p.client.create();
    const queue_m = p.queue.create("test-ctrl");
    const reconciler_m = p.reconciler.create("test-ctrl");
    const informer_m = p.informer.create("test-ctrl");
    const leader_m = p.leader.create();

    // Assert
    client_m.request_total.inc();
    queue_m.depth.set(5.0);
    reconciler_m.reconcile_total.inc();
    informer_m.watch_events_total.inc();
    leader_m.is_leader.set(1.0);
}

test "custom ClientMetrics.Factory receives 10 calls" {
    // Arrange
    const TestFactory = struct {
        call_count: u32 = 0,

        fn newCounter(raw: ?*anyopaque) Counter {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Counter.noop;
        }
        fn newHistogram(raw: ?*anyopaque) Histogram {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Histogram.noop;
        }
        fn newGauge(raw: ?*anyopaque) Gauge {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Gauge.noop;
        }

        const vtable: ClientMetrics.Factory.VTable = .{
            .new_request_total = newCounter,
            .new_request_latency = newHistogram,
            .new_request_error_total = newCounter,
            .new_retry_total = newCounter,
            .new_rate_limiter_latency = newHistogram,
            .new_circuit_breaker_state = newGauge,
            .new_circuit_breaker_trip_total = newCounter,
            .new_pool_size = newGauge,
            .new_pool_idle_connections = newGauge,
            .new_pool_active_connections = newGauge,
        };
    };

    var tf = TestFactory{};
    const factory: ClientMetrics.Factory = .{ .ptr = @ptrCast(&tf), .vtable = &TestFactory.vtable };

    // Act
    _ = factory.create();

    // Assert
    try testing.expectEqual(@as(u32, 10), tf.call_count);
}

test "custom QueueMetrics.Factory receives 6 calls" {
    // Arrange
    const TestFactory = struct {
        call_count: u32 = 0,

        fn newNamedCounter(raw: ?*anyopaque, _: []const u8) Counter {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Counter.noop;
        }
        fn newNamedHistogram(raw: ?*anyopaque, _: []const u8) Histogram {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Histogram.noop;
        }
        fn newNamedGauge(raw: ?*anyopaque, _: []const u8) Gauge {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Gauge.noop;
        }

        const vtable: QueueMetrics.Factory.VTable = .{
            .new_queue_depth = newNamedGauge,
            .new_queue_adds_total = newNamedCounter,
            .new_queue_latency = newNamedHistogram,
            .new_queue_work_duration = newNamedHistogram,
            .new_queue_retries_total = newNamedCounter,
            .new_queue_longest_running = newNamedGauge,
        };
    };

    var tf = TestFactory{};
    const factory: QueueMetrics.Factory = .{ .ptr = @ptrCast(&tf), .vtable = &TestFactory.vtable };

    // Act
    _ = factory.create("my-ctrl");

    // Assert
    try testing.expectEqual(@as(u32, 6), tf.call_count);
}

test "custom ReconcilerMetrics.Factory receives 4 calls" {
    // Arrange
    const TestFactory = struct {
        call_count: u32 = 0,

        fn newNamedCounter(raw: ?*anyopaque, _: []const u8) Counter {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Counter.noop;
        }
        fn newNamedHistogram(raw: ?*anyopaque, _: []const u8) Histogram {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Histogram.noop;
        }
        fn newNamedGauge(raw: ?*anyopaque, _: []const u8) Gauge {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Gauge.noop;
        }

        const vtable: ReconcilerMetrics.Factory.VTable = .{
            .new_reconcile_total = newNamedCounter,
            .new_reconcile_errors_total = newNamedCounter,
            .new_reconcile_duration = newNamedHistogram,
            .new_active_workers = newNamedGauge,
        };
    };

    var tf = TestFactory{};
    const factory: ReconcilerMetrics.Factory = .{ .ptr = @ptrCast(&tf), .vtable = &TestFactory.vtable };

    // Act
    _ = factory.create("my-ctrl");

    // Assert
    try testing.expectEqual(@as(u32, 4), tf.call_count);
}

test "custom InformerMetrics.Factory receives 5 calls" {
    // Arrange
    const TestFactory = struct {
        call_count: u32 = 0,

        fn newNamedCounter(raw: ?*anyopaque, _: []const u8) Counter {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Counter.noop;
        }
        fn newNamedHistogram(raw: ?*anyopaque, _: []const u8) Histogram {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Histogram.noop;
        }
        fn newNamedGauge(raw: ?*anyopaque, _: []const u8) Gauge {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Gauge.noop;
        }

        const vtable: InformerMetrics.Factory.VTable = .{
            .new_watch_events_total = newNamedCounter,
            .new_watch_restarts_total = newNamedCounter,
            .new_list_duration = newNamedHistogram,
            .new_store_object_count = newNamedGauge,
            .new_initial_list_synced = newNamedGauge,
        };
    };

    var tf = TestFactory{};
    const factory: InformerMetrics.Factory = .{ .ptr = @ptrCast(&tf), .vtable = &TestFactory.vtable };

    // Act
    _ = factory.create("my-ctrl");

    // Assert
    try testing.expectEqual(@as(u32, 5), tf.call_count);
}

test "custom LeaderMetrics.Factory receives 2 calls" {
    // Arrange
    const TestFactory = struct {
        call_count: u32 = 0,

        fn newGauge(raw: ?*anyopaque) Gauge {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Gauge.noop;
        }
        fn newCounter(raw: ?*anyopaque) Counter {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.call_count += 1;
            return Counter.noop;
        }

        const vtable: LeaderMetrics.Factory.VTable = .{
            .new_leader_is_leader = newGauge,
            .new_leader_transitions_total = newCounter,
        };
    };

    var tf = TestFactory{};
    const factory: LeaderMetrics.Factory = .{ .ptr = @ptrCast(&tf), .vtable = &TestFactory.vtable };

    // Act
    _ = factory.create();

    // Assert
    try testing.expectEqual(@as(u32, 2), tf.call_count);
}
