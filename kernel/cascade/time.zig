// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const wallclock = struct {
    /// This is an opaque timer tick, to acquire an actual time value, use `elapsed`.
    pub const Tick = enum(u64) {
        zero = 0,

        _,
    };

    /// Read the wallclock value.
    pub inline fn read() Tick {
        return globals.readFn();
    }

    /// Returns the duration between `value1` and `value2`, where `value2 >= value1`.
    ///
    /// Counter wraparound is assumed to have not occured.
    pub inline fn elapsed(value1: Tick, value2: Tick) core.Duration {
        return globals.elapsedFn(value1, value2);
    }

    const globals = struct {
        /// Set by `init.initializeTime`.
        var readFn: *const fn () Tick = undefined;

        /// Set by `init.initializeTime`.
        var elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration = undefined;
    };
};

pub const per_executor_periodic = struct {
    /// Enables a per-executor scheduler interrupt to be delivered every `period`.
    pub inline fn enableInterrupt(period: core.Duration) void {
        return globals.enableInterruptFn(period);
    }

    const globals = struct {
        /// Set by `init.initializeTime`.
        var enableInterruptFn: *const fn (period: core.Duration) void = undefined;
    };
};

pub const init = struct {
    const init_log = cascade.debug.log.scoped(.time_init);

    /// Attempts to capture the wallclock time at the start of the system using the most likely time source.
    ///
    /// For example on x86_64 this is the TSC.
    pub fn tryCaptureStandardWallclockStartTime() void {
        globals.kernel_start_time = .{ .kernel_start = arch.init.getStandardWallclockStartTime() };
    }

    pub fn initializeTime(current_task: Task.Current) !void {
        var candidate_time_sources: CandidateTimeSources = .{};
        arch.init.registerArchitecturalTimeSources(current_task, &candidate_time_sources);

        const time_sources: []CandidateTimeSource = candidate_time_sources.candidate_time_sources.slice();

        const reference_counter = getReferenceCounter(current_task, time_sources);

        const wallclock_options = getWallclockTimeSource(current_task, time_sources, reference_counter);
        wallclock.globals.readFn = wallclock_options.readFn;
        wallclock.globals.elapsedFn = wallclock_options.elapsedFn;

        const per_executor_periodic_options = getPerExecutorPeriodicTimeSource(
            current_task,
            time_sources,
            reference_counter,
        );
        per_executor_periodic.globals.enableInterruptFn = per_executor_periodic_options.enableInterruptFn;

        switch (globals.kernel_start_time) {
            .kernel_start => |tick| init_log.debug(
                current_task,
                "time initialized {f} after kernel start, spent {f} in firmware and bootloader before kernel start",
                .{
                    wallclock.elapsed(tick, wallclock.read()),
                    wallclock.elapsed(.zero, tick),
                },
            ),
            .time_system_start => init_log.debug(
                current_task,
                "time initialized {f} after system start (includes early kernel init, firmware and bootloader time)",
                .{
                    wallclock.elapsed(.zero, wallclock.read()),
                },
            ),
        }
    }

    pub fn printInitializationTime(writer: *std.Io.Writer) !void {
        try writer.print(
            "initialization complete - time since kernel start: {f} - time since system start: {f}\n",
            .{
                wallclock.elapsed(
                    switch (globals.kernel_start_time) {
                        inline else => |tick| tick,
                    },
                    wallclock.read(),
                ),
                wallclock.elapsed(
                    .zero,
                    wallclock.read(),
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
            current_task: Task.Current,
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

            init_log.debug(current_task, "adding time source: {s}", .{time_source.name});
            init_log.debug(current_task, "  priority: {}", .{time_source.priority});
            init_log.debug(current_task, "  reference counter: {} - wall clock: {} - per-executor periodic: {}", .{
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
            current_task: Task.Current,
            reference_counter: ReferenceCounter,
        ) void {
            if (candidate_time_source.initialized) return;
            switch (candidate_time_source.initialization) {
                .none => {},
                .simple => |simple| simple(current_task),
                .calibration_required => |calibration_required| calibration_required(current_task, reference_counter),
            }
            candidate_time_source.initialized = true;
        }

        pub const Initialization = union(enum) {
            none,
            simple: *const fn (current_task: Task.Current) void,
            calibration_required: *const fn (current_task: Task.Current, reference_counter: ReferenceCounter) void,
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
            /// This is `true` only if this is the source used by `init.tryCaptureStandardWallclockStartTime`.
            ///
            /// For example on x86_64 this is the TSC.
            standard_wallclock_source: bool,

            pub const Tick = wallclock.Tick;
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
        current_task: Task.Current,
        time_sources: []CandidateTimeSource,
    ) ReferenceCounter {
        const time_source = findAndInitializeTimeSource(current_task, time_sources, .{
            .pre_calibrated = true,
            .reference_counter = true,
        }, undefined) orelse @panic("no reference counter found");

        init_log.debug(current_task, "using reference counter: {s}", .{time_source.name});

        const reference_counter_impl = time_source.reference_counter.?;

        return .{
            ._prepareToWaitForFn = reference_counter_impl.prepareToWaitForFn,
            ._waitForFn = reference_counter_impl.waitForFn,
        };
    }

    fn getWallclockTimeSource(
        current_task: Task.Current,
        time_sources: []CandidateTimeSource,
        reference_counter: ReferenceCounter,
    ) CandidateTimeSource.WallclockOptions {
        const time_source = findAndInitializeTimeSource(current_task, time_sources, .{
            .wallclock = true,
        }, reference_counter) orelse @panic("no wallclock found");

        init_log.debug(current_task, "using wallclock: {s}", .{time_source.name});

        const wallclock_impl = time_source.wallclock.?;

        if (!wallclock_impl.standard_wallclock_source) {
            init_log.warn(
                current_task,
                "wallclock is not the standard wallclock source - setting kernel start time to now",
                .{},
            );
            globals.kernel_start_time = .{ .time_system_start = wallclock_impl.readFn() };
        }

        return wallclock_impl;
    }

    fn getPerExecutorPeriodicTimeSource(
        current_task: Task.Current,
        time_sources: []CandidateTimeSource,
        reference_counter: ReferenceCounter,
    ) CandidateTimeSource.PerExecutorPeriodicOptions {
        const time_source = findAndInitializeTimeSource(current_task, time_sources, .{
            .per_executor_periodic = true,
        }, reference_counter) orelse @panic("no per-executor periodic found");

        init_log.debug(current_task, "using per-executor periodic: {s}", .{time_source.name});

        return time_source.per_executor_periodic.?;
    }

    const TimeSourceQuery = struct {
        pre_calibrated: bool = false,

        reference_counter: bool = false,

        wallclock: bool = false,

        per_executor_periodic: bool = false,
    };

    fn findAndInitializeTimeSource(
        current_task: Task.Current,
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

        if (opt_best_candidate) |best_candidate| best_candidate.initialize(current_task, reference_counter);

        return opt_best_candidate;
    }

    const StartTime = union(enum) {
        /// The wallclock tick at kernel start.
        kernel_start: wallclock.Tick,

        /// The wallclock tick upon initialization of the time system.
        time_system_start: wallclock.Tick,
    };

    const globals = struct {
        /// Upon kernel start this is captured by `init.tryCaptureStandardWallclockStartTime` as variant `.kernel_start`.
        ///
        /// Then upon time system initialization in `initializeTime` if the wallclock source used by
        /// `init.tryCaptureStandardWallclockStartTime` is not the wallclock that is selected by `getWallclockTimeSource` then a
        /// tick is captured from the selected wallclock and is stored as variant `.time_system_start`.
        var kernel_start_time: StartTime = undefined;
    };
};
