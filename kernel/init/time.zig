// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Attempts to capture the wallclock time at the start of the system using the most likely time source.
///
/// For example on x86_64 this is the TSC.
pub fn tryCaptureStandardWallclockStartTime() void {
    globals.kernel_start_time = .{ .kernel_start = arch.init.getStandardWallclockStartTime() };
}

pub fn initializeTime(context: *cascade.Context) !void {
    var candidate_time_sources: CandidateTimeSources = .{};
    arch.init.registerArchitecturalTimeSources(context, &candidate_time_sources);

    const time_sources: []CandidateTimeSource = candidate_time_sources.candidate_time_sources.slice();

    const reference_counter = getReferenceCounter(context, time_sources);

    const wallclock = getWallclockTimeSource(context, time_sources, reference_counter);
    cascade.time.wallclock.globals.readFn = wallclock.readFn;
    cascade.time.wallclock.globals.elapsedFn = wallclock.elapsedFn;

    const per_executor_periodic = getPerExecutorPeriodicTimeSource(context, time_sources, reference_counter);
    cascade.time.per_executor_periodic.globals.enableInterruptFn = per_executor_periodic.enableInterruptFn;

    switch (globals.kernel_start_time) {
        .kernel_start => |tick| {
            log.debug(
                context,
                "time initialized {f} after kernel start, spent {f} in firmware and bootloader before kernel start",
                .{
                    cascade.time.wallclock.elapsed(tick, cascade.time.wallclock.read()),
                    cascade.time.wallclock.elapsed(.zero, tick),
                },
            );
        },
        .time_system_start => {
            log.debug(
                context,
                "time initialized {f} after system start (includes early kernel init, firmware and bootloader time)",
                .{
                    cascade.time.wallclock.elapsed(.zero, cascade.time.wallclock.read()),
                },
            );
        },
    }
}

pub fn printInitializationTime(writer: *std.Io.Writer) !void {
    try writer.print(
        "initialization complete - time since kernel start: {f} - time since system start: {f}\n",
        .{
            cascade.time.wallclock.elapsed(
                switch (globals.kernel_start_time) {
                    inline else => |tick| tick,
                },
                cascade.time.wallclock.read(),
            ),
            cascade.time.wallclock.elapsed(
                .zero,
                cascade.time.wallclock.read(),
            ),
        },
    );
}

pub const CandidateTimeSources = struct {
    candidate_time_sources: core.containers.BoundedArray(
        CandidateTimeSource,
        cascade.config.maximum_number_of_time_sources,
    ) = .{},

    pub fn addTimeSource(
        candidate_time_sources: *CandidateTimeSources,
        context: *cascade.Context,
        time_source: CandidateTimeSource,
    ) void {
        if (time_source.reference_counter != null) {
            if (time_source.initialization == .calibration_required) {
                std.debug.panic(
                    "reference counter cannot require calibration: {s}",
                    .{time_source.name},
                );
            }
        }

        candidate_time_sources.candidate_time_sources.append(time_source) catch {
            @panic("exceeded maximum number of time sources");
        };

        log.debug(context, "adding time source: {s}", .{time_source.name});
        log.debug(context, "  priority: {}", .{time_source.priority});
        log.debug(context, "  reference counter: {} - wall clock: {} - per-executor periodic: {}", .{
            time_source.reference_counter != null,
            time_source.wallclock != null,
            time_source.per_executor_periodic != null,
        });
    }
};

pub const CandidateTimeSource = struct {
    name: []const u8,

    priority: u8,

    initialization: Initialization = .none,

    /// Provided if the time source is usable as a reference counter.
    ///
    /// To be a valid reference counter the time source must not require calibration.
    ///
    /// NOTE: The reference counter interface is only used during initialization.
    reference_counter: ?ReferenceCounterOptions = null,

    /// Provided if the time source is usable as a wallclock.
    wallclock: ?WallclockOptions = null,

    /// Provided if the time source is usable as a per-executor periodic interrupt.
    ///
    /// If there is only one executor then a non per-executor time source is acceptable.
    per_executor_periodic: ?PerExecutorPeriodicOptions = null,

    initialized: bool = false,

    fn initialize(
        candidate_time_source: *CandidateTimeSource,
        context: *cascade.Context,
        reference_counter: ReferenceCounter,
    ) void {
        if (candidate_time_source.initialized) return;
        switch (candidate_time_source.initialization) {
            .none => {},
            .simple => |simple| simple(context),
            .calibration_required => |calibration_required| calibration_required(context, reference_counter),
        }
        candidate_time_source.initialized = true;
    }

    pub const Initialization = union(enum) {
        none,
        simple: *const fn (context: *cascade.Context) void,
        calibration_required: *const fn (context: *cascade.Context, reference_counter: ReferenceCounter) void,
    };

    pub const ReferenceCounterOptions = struct {
        /// Prepares the counter to wait for `duration`.
        ///
        /// Must be called before `waitForFn` is called.
        prepareToWaitForFn: *const fn (duration: core.Duration) void,

        /// Waits for `duration`.
        ///
        /// Must be called after `prepareToWaitForFn` is called.
        waitForFn: *const fn (duration: core.Duration) void,
    };

    pub const WallclockOptions = struct {
        /// Read the wallclock value.
        readFn: *const fn () Tick,

        /// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
        ///
        /// Counter wraparound is assumed to have not occured.
        elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration,

        /// Whether this wallclock is the standard wallclock source for the current architecture.
        ///
        /// This is `true` only if this is the source used by `tryCaptureStandardWallclockStartTime`.
        ///
        /// For example on x86_64 this is the TSC.
        standard_wallclock_source: bool,

        pub const Tick = cascade.time.wallclock.Tick;
    };

    pub const PerExecutorPeriodicOptions = struct {
        /// Enables a per-executor scheduler interrupt to be delivered every `period`.
        enableInterruptFn: *const fn (period: core.Duration) void,
    };
};

pub const ReferenceCounter = struct {
    /// Prepares the counter to wait for `duration`.
    ///
    /// Must be called before `_waitForFn` is called.
    _prepareToWaitForFn: *const fn (duration: core.Duration) void,

    /// Waits for `duration`.
    ///
    /// Must be called after `_prepareToWaitForFn` is called.
    _waitForFn: *const fn (duration: core.Duration) void,

    /// Prepares the counter to wait for `duration`.
    ///
    /// Must be called before `waitFor` is called.
    pub inline fn prepareToWaitFor(
        reference_counter: ReferenceCounter,
        duration: core.Duration,
    ) void {
        reference_counter._prepareToWaitForFn(duration);
    }

    /// Waits for `duration`.
    ///
    /// Must be called after `prepareToWaitFor` is called.
    pub inline fn waitFor(
        reference_counter: ReferenceCounter,
        duration: core.Duration,
    ) void {
        reference_counter._waitForFn(duration);
    }
};

fn getReferenceCounter(
    context: *cascade.Context,
    time_sources: []CandidateTimeSource,
) ReferenceCounter {
    const time_source = findAndInitializeTimeSource(context, time_sources, .{
        .pre_calibrated = true,
        .reference_counter = true,
    }, undefined) orelse @panic("no reference counter found");

    log.debug(context, "using reference counter: {s}", .{time_source.name});

    const reference_counter_impl = time_source.reference_counter.?;

    return .{
        ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
        ._waitForFn = reference_counter_impl.waitForFn,
    };
}

fn getWallclockTimeSource(
    context: *cascade.Context,
    time_sources: []CandidateTimeSource,
    reference_counter: ReferenceCounter,
) CandidateTimeSource.WallclockOptions {
    const time_source = findAndInitializeTimeSource(context, time_sources, .{
        .wallclock = true,
    }, reference_counter) orelse @panic("no wallclock found");

    log.debug(context, "using wallclock: {s}", .{time_source.name});

    const wallclock_impl = time_source.wallclock.?;

    if (!wallclock_impl.standard_wallclock_source) {
        log.warn(
            context,
            "wallclock is not the standard wallclock source - setting kernel start time to now",
            .{},
        );
        globals.kernel_start_time = .{ .time_system_start = wallclock_impl.readFn() };
    }

    return wallclock_impl;
}

fn getPerExecutorPeriodicTimeSource(
    context: *cascade.Context,
    time_sources: []CandidateTimeSource,
    reference_counter: ReferenceCounter,
) CandidateTimeSource.PerExecutorPeriodicOptions {
    const time_source = findAndInitializeTimeSource(context, time_sources, .{
        .per_executor_periodic = true,
    }, reference_counter) orelse @panic("no per-executor periodic found");

    log.debug(context, "using per-executor periodic: {s}", .{time_source.name});

    return time_source.per_executor_periodic.?;
}

const TimeSourceQuery = struct {
    pre_calibrated: bool = false,

    reference_counter: bool = false,

    wallclock: bool = false,

    per_executor_periodic: bool = false,
};

fn findAndInitializeTimeSource(
    context: *cascade.Context,
    time_sources: []CandidateTimeSource,
    query: TimeSourceQuery,
    reference_counter: ReferenceCounter,
) ?*CandidateTimeSource {
    var opt_best_candidate: ?*CandidateTimeSource = null;

    for (time_sources) |*time_source| {
        if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

        if (query.reference_counter and time_source.reference_counter == null) continue;

        if (query.wallclock and time_source.wallclock == null) continue;

        if (query.per_executor_periodic and time_source.per_executor_periodic == null) continue;

        if (opt_best_candidate) |best_candidate| {
            if (time_source.priority > best_candidate.priority) opt_best_candidate = time_source;
        } else {
            opt_best_candidate = time_source;
        }
    }

    if (opt_best_candidate) |best_candidate| best_candidate.initialize(context, reference_counter);

    return opt_best_candidate;
}

const StartTime = union(enum) {
    /// The wallclock tick at kernel start.
    kernel_start: cascade.time.wallclock.Tick,

    /// The wallclock tick upon initialization of the time system.
    time_system_start: cascade.time.wallclock.Tick,
};

const globals = struct {
    /// Upon kernel start this is captured by `tryCaptureStandardWallclockStartTime` as variant `.kernel_start`.
    ///
    /// Then upon time system initialization in `initializeTime` if the wallclock source used by
    /// `tryCaptureStandardWallclockStartTime` is not the wallclock that is selected by `getWallclockTimeSource` then a
    /// tick is captured from the selected wallclock and is stored as variant `.time_system_start`.
    var kernel_start_time: StartTime = undefined;
};

const arch = @import("arch");
const cascade = @import("cascade");

const core = @import("core");
const log = cascade.debug.log.scoped(.time_init);
const std = @import("std");
