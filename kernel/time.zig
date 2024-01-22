// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.time);

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const wallclock = struct {
    var readFn: *const fn () u64 = undefined;
    var elapsedFn: *const fn (value1: u64, value2: u64) core.Duration = undefined;

    /// Read the wallclock value.
    ///
    /// The value returned is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub inline fn read() u64 {
        return readFn();
    }

    /// Returns the number of nanoseconds between `value1` and `value2`, where `value2` occurs after `value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub inline fn elapsed(value1: u64, value2: u64) core.Duration {
        return elapsedFn(value1, value2);
    }
};

pub const init = struct {
    pub fn initTime() linksection(kernel.info.init_code) void {
        log.debug("registering architectural time sources", .{});
        kernel.arch.init.registerArchitecturalTimeSources();

        const reference_counter = getReferenceCounter();

        configureWallclockTimeSource(reference_counter);
    }

    var candidate_time_sources: std.BoundedArray(CandidateTimeSource, 8) linksection(kernel.info.init_data) = .{};

    pub const CandidateTimeSource = struct {
        name: []const u8,

        priority: u8,

        initialization: Initialization = .none,

        reference_counter: ?ReferenceCounterOptions = null,

        wallclock: ?WallclockOptions = null,

        initialized: bool = false,

        fn initialize(
            self: *CandidateTimeSource,
            reference_counter: ReferenceCounter,
        ) linksection(kernel.info.init_code) void {
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

    pub fn addTimeSource(time_source: CandidateTimeSource) linksection(kernel.info.init_code) void {
        if (time_source.reference_counter != null) {
            if (time_source.initialization == .calibration_required) {
                core.panic("reference counter cannot require calibratation");
            }
        }

        candidate_time_sources.append(time_source) catch {
            core.panic("exceeded maximum number of time sources");
        };

        log.debug("adding time source: {s}", .{time_source.name});
        log.debug("  priority: {}", .{time_source.priority});
        log.debug("  reference counter: {} - wall clock: {}", .{
            time_source.reference_counter != null,
            time_source.wallclock != null,
        });
    }

    const TimeSourceQuery = struct {
        pre_calibrated: bool = false,

        reference_counter: bool = false,

        wallclock: bool = false,
    };

    fn findAndInitializeTimeSource(query: TimeSourceQuery, reference_counter: ReferenceCounter) linksection(kernel.info.init_code) ?*CandidateTimeSource {
        var opt_best_candidate: ?*CandidateTimeSource = null;

        for (candidate_time_sources.slice()) |*time_source| {
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

    fn getReferenceCounter() linksection(kernel.info.init_code) ReferenceCounter {
        const time_source = findAndInitializeTimeSource(.{
            .pre_calibrated = true,
            .reference_counter = true,
        }, undefined) orelse core.panic("no reference counter found");

        log.debug("using reference counter: {s}", .{time_source.name});

        const reference_counter_impl = time_source.reference_counter.?;

        return .{
            ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
            ._waitForFn = reference_counter_impl.waitForFn,
        };
    }

    fn configureWallclockTimeSource(
        reference_counter: ReferenceCounter,
    ) linksection(kernel.info.init_code) void {
        const time_source = findAndInitializeTimeSource(.{
            .wallclock = true,
        }, reference_counter) orelse core.panic("no wallclock found");

        log.debug("using wallclock: {s}", .{time_source.name});

        const wallclock_impl = time_source.wallclock.?;

        wallclock.readFn = wallclock_impl.readFn;
        wallclock.elapsedFn = wallclock_impl.elapsedFn;
    }

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
        pub fn prepareToWaitFor(
            self: ReferenceCounter,
            duration: core.Duration,
        ) linksection(kernel.info.init_code) callconv(core.inline_in_non_debug_calling_convention) void {
            self._prepareToWaitForFn(duration);
        }

        /// Waits for `duration`.
        ///
        /// Must be called after `prepareToWaitFor` is called.
        pub fn waitFor(
            self: ReferenceCounter,
            duration: core.Duration,
        ) linksection(kernel.info.init_code) callconv(core.inline_in_non_debug_calling_convention) void {
            self._waitForFn(duration);
        }
    };
};
