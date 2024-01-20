// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const core = @import("core");
const kernel = @import("kernel");
const std = @import("std");

const log = kernel.debug.log.scoped(.time);

pub const init = struct {
    pub fn initTime() linksection(kernel.info.init_code) void {
        log.debug("registering architectural time sources", .{});
        kernel.arch.init.registerArchitecturalTimeSources();

        const reference_counter = getReferenceCounter();
    }

    fn getReferenceCounter() linksection(kernel.info.init_code) ReferenceCounterTimeSource {
        const time_source = findTimeSource(.{
            .pre_calibrated = true,
            .reference_counter = true,
        }) orelse core.panic("no reference counter found");

        log.debug("using reference counter: {s}", .{time_source.name});

        time_source.initialize(undefined);

        const reference_counter = time_source.reference_counter.?;

        return .{
            ._prepareToWaitForFn = reference_counter.prepareToWaitForFn,
            ._waitForFn = reference_counter.waitForFn,
        };
    }

    var candidate_time_sources: std.BoundedArray(CandidateTimeSource, 8) linksection(kernel.info.init_data) = .{};

    pub const CandidateTimeSource = struct {
        name: []const u8,

        priority: u8,

        per_core: bool,

        initialization: Initialization = .none,

        reference_counter: ?ReferenceCounter = null,

        list_next: ?*CandidateTimeSource = null,

        fn initialize(
            self: *CandidateTimeSource,
            reference_time_source: ReferenceCounterTimeSource,
        ) linksection(kernel.info.init_code) void {
            switch (self.initialization) {
                .none => {},
                .simple => |simple| simple(),
                .calibration_required => |calibration_required| calibration_required(reference_time_source),
            }
        }

        pub const Initialization = union(enum) {
            none,
            simple: *const fn () void,
            calibration_required: *const fn (reference_time_source: ReferenceCounterTimeSource) void,
        };

        pub const ReferenceCounter = struct {
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
    };

    fn findTimeSource(query: TimeSourceQuery) linksection(kernel.info.init_code) ?*CandidateTimeSource {
        var opt_time_source = candidate_time_source_list_start;

        while (opt_time_source) |time_source| : (opt_time_source = time_source.list_next) {
            if (query.pre_calibrated and time_source.initialization == .calibration_required) continue;

            if (query.reference_counter and time_source.reference_counter == null) continue;

            return time_source;
        }

        return null;
    }

    pub const ReferenceCounterTimeSource = struct {
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
        pub inline fn prepareToWaitFor(self: ReferenceCounterTimeSource, duration: core.Duration) void {
            self._prepareToWaitForFn(duration);
        }

        /// Waits for `duration`.
        ///
        /// Must be called after `prepareToWaitFor` is called.
        pub inline fn waitFor(self: ReferenceCounterTimeSource, duration: core.Duration) void {
            self._waitForFn(duration);
        }
    };
};
