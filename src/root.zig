//! Kube-zig: a type-safe Kubernetes client library for Zig.
//!
//! Plain-HTTP mode (via `kubectl proxy`):
//! ```zig
//! const kube_zig = @import("kube-zig");
//!
//! var client = try kube_zig.Client.init(allocator, "http://127.0.0.1:8001", .{});
//! defer client.deinit();
//!
//! const pods = kube_zig.Api(kube_zig.types.CoreV1Pod).init(&client, client.context(), "default");
//! const list = try (try pods.list(.{})).value();
//! defer list.deinit();
//! ```
//!
//! In-cluster mode (HTTPS + service-account token):
//! ```zig
//! const kube_zig = @import("kube-zig");
//!
//! var config = try kube_zig.InClusterConfig.init(allocator);
//! defer config.deinit(allocator);
//!
//! var client = try kube_zig.Client.initInCluster(allocator, config, .{});
//! defer client.deinit();
//!
//! const pods = kube_zig.Api(kube_zig.types.CoreV1Pod).init(&client, client.context(), config.namespace);
//! const list = try (try pods.list(.{})).value();
//! defer list.deinit();
//! ```

const client_mod = @import("client/Client.zig");
pub const Client = client_mod.Client;
pub const ClientOptions = Client.ClientOptions;
pub const Transport = client_mod.Transport;
pub const BodySerializer = client_mod.BodySerializer;
pub const StdHttpTransport = client_mod.StdHttpTransport;
pub const MockTransport = @import("client/mock.zig").MockTransport;
pub const RequestOptions = client_mod.RequestOptions;
pub const TransportResponse = client_mod.TransportResponse;
pub const ApiRequestError = Client.ApiRequestError;
pub const TransportError = Client.TransportError;
pub const ParseError = Client.ParseError;
pub const RequestError = Client.RequestError;
pub const ApiErrorResponse = Client.ApiErrorResponse;
pub const ApiResult = Client.ApiResult;
pub const FlowControl = @import("client/flow_control.zig").FlowControl;
pub const PoolStats = client_mod.PoolStats;

const Api_mod = @import("api/Api.zig");
pub const Api = Api_mod.Api;

const options_mod = @import("api/options.zig");
pub const PatchType = options_mod.PatchType;
pub const PatchOptions = options_mod.PatchOptions;
pub const ApplyOptions = options_mod.ApplyOptions;
pub const PropagationPolicy = options_mod.PropagationPolicy;
pub const ResourceVersionMatch = options_mod.ResourceVersionMatch;
pub const ListOptions = options_mod.ListOptions;
pub const WriteOptions = options_mod.WriteOptions;
pub const DeleteOptions = options_mod.DeleteOptions;
pub const LogOptions = options_mod.LogOptions;
pub const WatchOptions = options_mod.WatchOptions;
pub const RawResponse = Client.RawResponse;

const watch_mod = @import("api/watch.zig");
pub const WatchEvent = watch_mod.WatchEvent;
pub const WatchStream = watch_mod.WatchStream;
pub const ParsedEvent = watch_mod.ParsedEvent;
pub const StreamState = client_mod.StreamState;
pub const StreamResponse = client_mod.StreamResponse;

const store_mod = @import("cache/store.zig");
pub const Store = store_mod.Store;
pub const ObjectKey = @import("object_key.zig").ObjectKey;

const reflector_mod = @import("cache/reflector.zig");
pub const Reflector = reflector_mod.Reflector;
pub const ReflectorEvent = reflector_mod.ReflectorEvent;
pub const ReflectorOptions = reflector_mod.ReflectorOptions;
pub const ReflectorState = reflector_mod.ReflectorState;

const informer_mod = @import("cache/informer.zig");
pub const Informer = informer_mod.Informer;
pub const EventHandler = informer_mod.EventHandler;

pub const predicates = @import("cache/predicates.zig");

const work_queue_mod = @import("controller/work_queue.zig");
pub const WorkQueue = work_queue_mod.WorkQueue;

const reconciler_mod = @import("controller/reconciler.zig");
pub const Reconciler = reconciler_mod.Reconciler;
pub const ReconcileResult = reconciler_mod.Result;
pub const ReconcileFn = reconciler_mod.ReconcileFn;

const controller_mod = @import("controller/controller.zig");
pub const Controller = controller_mod.Controller;
pub const SecondaryInformer = controller_mod.SecondaryInformer;

pub const mapper = @import("controller/mapper.zig");

const controller_manager_mod = @import("controller/manager.zig");
pub const ControllerManager = controller_manager_mod.ControllerManager;
pub const Runnable = controller_manager_mod.Runnable;

const leader_election_mod = @import("features/leader_election.zig");
pub const LeaderElector = leader_election_mod.LeaderElector;
pub const LeaderElectionConfig = leader_election_mod.LeaderElectionConfig;

const event_recorder_mod = @import("features/event_recorder.zig");
pub const EventRecorder = event_recorder_mod.EventRecorder;
pub const EventType = event_recorder_mod.EventType;

pub const HealthCheck = @import("util/health_check.zig").HealthCheck;
const probe_server_mod = @import("features/probe_server.zig");
pub const ProbeServer = probe_server_mod.ProbeServer;

const dynamic_api_mod = @import("api/dynamic.zig");
pub const DynamicApi = dynamic_api_mod.DynamicApi;
pub const ResourceMeta = dynamic_api_mod.ResourceMeta;

pub const DiscoveryClient = @import("api/discovery.zig").DiscoveryClient;
pub const DiscoveryOptions = @import("api/discovery.zig").DiscoveryOptions;

const context_mod = @import("util/context.zig");
pub const Context = context_mod.Context;
pub const CancelSource = context_mod.CancelSource;
pub const interruptibleSleep = context_mod.interruptibleSleep;

pub const InClusterConfig = @import("client/incluster.zig").InClusterConfig;
pub const ProxyConfig = @import("client/proxy.zig").ProxyConfig;
pub const RetryPolicy = @import("util/retry.zig").RetryPolicy;
pub const retryOnConflict = @import("util/retry_conflict.zig").retryOnConflict;
pub const default_conflict_policy = @import("util/retry_conflict.zig").default_conflict_policy;
pub const RateLimiter = @import("util/rate_limit.zig").RateLimiter;
pub const CircuitBreaker = @import("util/circuit_breaker.zig").CircuitBreaker;

const metrics_mod = @import("util/metrics.zig");
pub const Counter = metrics_mod.Counter;
pub const Gauge = metrics_mod.Gauge;
pub const Histogram = metrics_mod.Histogram;
pub const MetricsProvider = metrics_mod.MetricsProvider;
pub const ClientMetrics = metrics_mod.ClientMetrics;
pub const QueueMetrics = metrics_mod.QueueMetrics;
pub const ReconcilerMetrics = metrics_mod.ReconcilerMetrics;
pub const InformerMetrics = metrics_mod.InformerMetrics;
pub const LeaderMetrics = metrics_mod.LeaderMetrics;

const logging_mod = @import("util/logging.zig");
pub const Logger = logging_mod.Logger;
pub const LogLevel = logging_mod.Level;
pub const LogField = logging_mod.Field;
pub const LogFieldValue = logging_mod.FieldValue;
pub const WithFieldsLogger = logging_mod.WithFieldsLogger;
pub const JsonStdoutLogger = logging_mod.JsonStdoutLogger;
pub const TextStdoutLogger = logging_mod.TextStdoutLogger;

const tracing_mod = @import("util/tracing.zig");
pub const TracerProvider = tracing_mod.TracerProvider;
pub const TraceId = tracing_mod.TraceId;
pub const SpanId = tracing_mod.SpanId;
pub const SpanContext = tracing_mod.SpanContext;
pub const SpanKind = tracing_mod.SpanKind;
pub const SpanStatus = tracing_mod.SpanStatus;
pub const Span = tracing_mod.Span;
pub const Attribute = tracing_mod.Attribute;
pub const SpanAttributeValue = tracing_mod.SpanAttributeValue;
pub const formatTraceparent = tracing_mod.formatTraceparent;
pub const parseTraceparent = tracing_mod.parseTraceparent;

pub const metadata = @import("util/metadata.zig");
pub const managed_fields = @import("util/managed_fields.zig");
pub const ssa = @import("util/ssa.zig");
pub const conditions = @import("util/conditions.zig");
pub const finalizers = @import("util/finalizers.zig");
pub const owner_ref = @import("util/owner_ref.zig");
pub const signal = @import("util/signal.zig");
pub const equality = @import("util/equality.zig");
pub const resource_shape = @import("util/resource_shape.zig");
pub const time = @import("util/time.zig");
pub const types = @import("types");
