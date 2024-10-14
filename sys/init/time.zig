// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

pub fn initializeTime() !void {
    var candidate_time_sources: CandidateTimeSources = .{};
    arch.init.registerArchitecturalTimeSources(&candidate_time_sources);
    const time_sources = candidate_time_sources.candidate_time_sources.slice();

    const reference_counter = getReferenceCounter(time_sources);

    configureWallclockTimeSource(time_sources, reference_counter);
}

pub const CandidateTimeSources = struct {
    candidate_time_sources: std.BoundedArray(CandidateTimeSource, kernel.config.maxium_number_of_time_sources) = .{},

    pub fn addTimeSource(self: *CandidateTimeSources, time_source: CandidateTimeSource) void {
        if (time_source.reference_counter != null) {
            if (time_source.initialization == .calibration_required) {
                core.panicFmt(
                    "reference counter cannot require calibration: {s}",
                    .{time_source.name},
                    null,
                );
            }
        }

        self.candidate_time_sources.append(time_source) catch {
            core.panic("exceeded maximum number of time sources", null);
        };

        log.debug("adding time source: {s}", .{time_source.name});
        log.debug("  priority: {}", .{time_source.priority});
        log.debug("  reference counter: {} - wall clock: {}", .{
            time_source.reference_counter != null,
            time_source.wallclock != null,
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

    initialized: bool = false,

    fn initialize(
        self: *CandidateTimeSource,
        reference_counter: ReferenceCounter,
    ) void {
        if (self.initialized) return;
        switch (self.initialization) {
            .none => {},
            .simple => |simple| simple(),
            .calibration_required => |calibration_required| calibration_required(reference_counter),
        }
        self.initialized = true;
    }

    pub const Initialization = union(enum) {
        none,
        simple: *const fn () void,
        calibration_required: *const fn (reference_counter: ReferenceCounter) void,
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
        ///
        /// The value returned is an opaque timer tick.
        readFn: *const fn () u64,

        /// Returns the number of nanoseconds between `value1` and `value2`, where `value2` occurs after `value1`.
        ///
        /// Counter wraparound is assumed to have not occured.
        elapsedFn: *const fn (value1: u64, value2: u64) core.Duration,
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
        self: ReferenceCounter,
        duration: core.Duration,
    ) void {
        self._prepareToWaitForFn(duration);
    }

    /// Waits for `duration`.
    ///
    /// Must be called after `prepareToWaitFor` is called.
    pub inline fn waitFor(
        self: ReferenceCounter,
        duration: core.Duration,
    ) void {
        self._waitForFn(duration);
    }
};

fn getReferenceCounter(time_sources: []CandidateTimeSource) ReferenceCounter {
    const time_source = findAndInitializeTimeSource(time_sources, .{
        .pre_calibrated = true,
        .reference_counter = true,
    }, undefined) orelse core.panic("no reference counter found", null);

    log.debug("using reference counter: {s}", .{time_source.name});

    const reference_counter_impl = time_source.reference_counter.?;

    return .{
        ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
        ._waitForFn = reference_counter_impl.waitForFn,
    };
}

fn configureWallclockTimeSource(
    time_sources: []CandidateTimeSource,
    reference_counter: ReferenceCounter,
) void {
    const time_source = findAndInitializeTimeSource(time_sources, .{
        .wallclock = true,
    }, reference_counter) orelse core.panic("no wallclock found", null);

    log.debug("using wallclock: {s}", .{time_source.name});

    const wallclock_impl = time_source.wallclock.?;

    kernel.time.wallclock.globals.readFn = wallclock_impl.readFn;
    kernel.time.wallclock.globals.elapsedFn = wallclock_impl.elapsedFn;
}

const TimeSourceQuery = struct {
    pre_calibrated: bool = false,

    reference_counter: bool = false,

    wallclock: bool = false,
};

fn findAndInitializeTimeSource(
    time_sources: []CandidateTimeSource,
    query: TimeSourceQuery,
    reference_counter: ReferenceCounter,
) ?*CandidateTimeSource {
    var opt_best_candidate: ?*CandidateTimeSource = null;

    for (time_sources) |*time_source| {
        if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

        if (query.reference_counter and time_source.reference_counter == null) continue;

        if (query.wallclock and time_source.wallclock == null) continue;

        if (opt_best_candidate) |best_candidate| {
            if (time_source.priority > best_candidate.priority) opt_best_candidate = time_source;
        } else {
            opt_best_candidate = time_source;
        }
    }

    if (opt_best_candidate) |best_candidate| best_candidate.initialize(reference_counter);

    return opt_best_candidate;
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const arch = @import("arch");
const log = kernel.log.scoped(.init_time);
