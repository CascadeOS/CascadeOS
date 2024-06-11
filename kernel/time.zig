// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.log.scoped(.time);

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const init = struct {
    pub fn initTime() void {
        log.debug("registering architectural time sources", .{});
        kernel.arch.init.registerArchitecturalTimeSources();

    var candidate_time_sources: std.BoundedArray(CandidateTimeSource, 8) = .{};

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
    };

    pub fn addTimeSource(time_source: CandidateTimeSource) void {
        if (time_source.reference_counter != null) {
            if (time_source.initialization == .calibration_required) {
                core.panic("reference counter cannot require calibration");
            }
        }

        candidate_time_sources.append(time_source) catch {
            core.panic("exceeded maximum number of time sources");
        };

        log.debug("adding time source: {s}", .{time_source.name});
        log.debug("  priority: {}", .{time_source.priority});
        log.debug("  reference counter: {}", .{
            time_source.reference_counter != null,
        });
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

    const TimeSourceQuery = struct {
        pre_calibrated: bool = false,

        reference_counter: bool = false,
    };

    fn findAndInitializeTimeSource(query: TimeSourceQuery, reference_counter: ReferenceCounter) ?*CandidateTimeSource {
        var opt_best_candidate: ?*CandidateTimeSource = null;

        for (candidate_time_sources.slice()) |*time_source| {
            if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

            if (query.reference_counter and time_source.reference_counter == null) continue;

            if (opt_best_candidate) |best_candidate| {
                if (time_source.priority > best_candidate.priority) opt_best_candidate = time_source;
            } else {
                opt_best_candidate = time_source;
            }
        }

        if (opt_best_candidate) |best_candidate| best_candidate.initialize(reference_counter);

        return opt_best_candidate;
    }

    fn getReferenceCounter() ReferenceCounter {
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
};
