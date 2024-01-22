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
    var wallclock_time_source: WallclockTimeSource = undefined;

    /// Read the wallclock value.
    ///
    /// The value returned is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub fn read() callconv(core.inline_in_non_debug_calling_convention) u64 {
        return wallclock_time_source.readCounterFn();
    }

    /// Returns the number of nanoseconds between `value1` and `value2`, where `value2` occurs after `value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub fn elapsed(value1: u64, value2: u64) callconv(core.inline_in_non_debug_calling_convention) core.Duration {
        return wallclock_time_source.elapsedFn(value1, value2);
    }

    const WallclockTimeSource = struct {
        /// Read the wallclock value.
        ///
        /// The value returned is an opaque timer tick.
        readCounterFn: *const fn () u64,

        /// Returns the number of nanoseconds between `value1` and `value2`, where `value2` occurs after `value1`.
        ///
        /// Counter wraparound is assumed to have not occured.
        elapsedFn: *const fn (value1: u64, value2: u64) core.Duration,
    };
};

pub const init = struct {
    pub fn initTime() linksection(kernel.info.init_code) void {
        log.debug("registering architectural time sources", .{});
        kernel.arch.init.registerArchitecturalTimeSources();

        const reference_counter = getReferenceCounter();

        wallclock.wallclock_time_source = getWallclockTimeSource(reference_counter);
    }

    var candidate_time_sources: std.BoundedArray(CandidateTimeSource, 8) linksection(kernel.info.init_data) = .{};

    pub const CandidateTimeSource = struct {
        name: []const u8,

        priority: u8,

        per_core: bool,

        initialization: Initialization = .none,

        reference_counter: ?ReferenceCounterOptions = null,

        wallclock: ?WallclockOptions = null,

        initialized: bool = false,

        list_next: ?*CandidateTimeSource = null,

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
            readCounterFn: *const fn () u64,

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

        const candidate_time_source = candidate_time_sources.addOne() catch {
            core.panic("exceeded maximum number of time sources");
        };

        candidate_time_source.* = time_source;
        addToLinkedList(candidate_time_source);

        log.debug("adding time source: {s}", .{candidate_time_source.name});
        log.debug("  priority: {}", .{candidate_time_source.priority});
        log.debug("  per core: {}", .{candidate_time_source.per_core});
    }

    var candidate_time_source_list_start: ?*CandidateTimeSource linksection(kernel.info.init_data) = null;

    fn addToLinkedList(
        time_source: *CandidateTimeSource,
    ) linksection(kernel.info.init_code) void {
        var parent_time_source_ptr: *?*CandidateTimeSource = &candidate_time_source_list_start;

        var opt_other_time_source: ?*CandidateTimeSource = parent_time_source_ptr.*;
        while (opt_other_time_source) |other_time_source| {
            if (time_source.priority > other_time_source.priority) {
                // we are higher priority so we should be first
                time_source.list_next = other_time_source;
                parent_time_source_ptr.* = time_source;
                return;
            }

            parent_time_source_ptr = &other_time_source.list_next;
            opt_other_time_source = other_time_source.list_next;
        }

        parent_time_source_ptr.* = time_source;
    }

    const TimeSourceQuery = struct {
        pre_calibrated: bool = false,

        reference_counter: bool = false,

        wallclock: bool = false,
    };

    fn findTimeSource(query: TimeSourceQuery) linksection(kernel.info.init_code) ?*CandidateTimeSource {
        var opt_time_source = candidate_time_source_list_start;

        while (opt_time_source) |time_source| : (opt_time_source = time_source.list_next) {
            if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

            if (query.reference_counter and time_source.reference_counter == null) continue;

            if (query.wallclock and time_source.wallclock == null) continue;

            return time_source;
        }

        return null;
    }

    fn getReferenceCounter() linksection(kernel.info.init_code) ReferenceCounter {
        const time_source = findTimeSource(.{
            .pre_calibrated = true,
            .reference_counter = true,
        }) orelse core.panic("no reference counter found");

        log.debug("using reference counter: {s}", .{time_source.name});

        time_source.initialize(undefined);

        const reference_counter_impl = time_source.reference_counter.?;

        return .{
            ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
            ._waitForFn = reference_counter_impl.waitForFn,
        };
    }

    fn getWallclockTimeSource(
        reference_counter: ReferenceCounter,
    ) linksection(kernel.info.init_code) wallclock.WallclockTimeSource {
        const time_source = findTimeSource(.{
            .wallclock = true,
        }) orelse core.panic("no wallclock found");

        log.debug("using wallclock: {s}", .{time_source.name});

        time_source.initialize(reference_counter);

        const wallclock_impl = time_source.wallclock.?;

        return .{
            .readCounterFn = wallclock_impl.readCounterFn,
            .elapsedFn = wallclock_impl.elapsedFn,
        };
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
