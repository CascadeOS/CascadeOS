// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

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

    /// The wallclock tick at kernel start or upon initialization of the time system.
    ///
    /// Upon kernel start this is captured by `init.tryCaptureStandardWallclockStartTime` then upon time system
    /// initialization in `init.initializeTime` if the selected wallclock source is not the standard wallclock the
    /// a tick is captured from the selected wallclock source at that time.
    pub var kernel_start: wallclock.Tick = undefined;

    /// Tracks whether the kernel start time stored in `kernel_start` is the kernel start time or the time system start
    /// time.
    ///
    /// This depends on whether the architecture standard wallclock source used for `init.tryCaptureStandardWallclockStartTime`
    /// is the wallclock source selected by the time system.
    ///
    /// This is only used for logging purposes during time system initialization.
    var kernel_start_type: enum { kernel_start, time_system_start } = .kernel_start;

    const globals = struct {
        // Initialized during `init.time.configureWallclockTimeSource`.
        var readFn: *const fn () Tick = undefined;
        // Initialized during `init.time.configureWallclockTimeSource`.
        var elapsedFn: *const fn (value1: Tick, value2: Tick) core.Duration = undefined;
    };
};

pub const per_executor_periodic = struct {
    /// Enables a per-executor scheduler interrupt to be delivered every `period`.
    pub inline fn enableInterrupt(period: core.Duration) void {
        return globals.enableInterruptFn(period);
    }

    const globals = struct {
        var enableInterruptFn: *const fn (period: core.Duration) void = undefined;
    };
};

/// Femptoseconds per nanosecond.
pub const fs_per_ns = 1000000;

/// Femptoseconds per second.
pub const fs_per_s = fs_per_ns * std.time.ns_per_s;

pub const init = struct {
    /// Attempts to capture the wallclock time at the start of the system using the most likely time source.
    ///
    /// For example on x86_64 this is the TSC.
    pub fn tryCaptureStandardWallclockStartTime() void {
        wallclock.kernel_start = arch.init.getStandardWallclockStartTime();
        // wallclock.kernel_start_type already set to .kernel_start
    }

    pub fn initializeTime() !void {
        var candidate_time_sources: CandidateTimeSources = .{};
        arch.init.registerArchitecturalTimeSources(&candidate_time_sources);

        const time_sources = candidate_time_sources.candidate_time_sources.slice();

        const reference_counter = getReferenceCounter(time_sources);

        configureWallclockTimeSource(time_sources, reference_counter);
        configurePerExecutorPeriodicTimeSource(time_sources, reference_counter);

        switch (wallclock.kernel_start_type) {
            .kernel_start => {
                init_log.debug(
                    "time initialized {f} after kernel start, spent {f} in firmware and bootloader before kernel start",
                    .{
                        wallclock.elapsed(wallclock.kernel_start, wallclock.read()),
                        wallclock.elapsed(.zero, wallclock.kernel_start),
                    },
                );
            },
            .time_system_start => {
                init_log.debug(
                    "time initialized {f} after system start (includes early kernel init, firmware and bootloader time)",
                    .{
                        wallclock.elapsed(.zero, wallclock.read()),
                    },
                );
            },
        }
    }

    pub const CandidateTimeSources = struct {
        candidate_time_sources: std.BoundedArray(
            CandidateTimeSource,
            kernel.config.maximum_number_of_time_sources,
        ) = .{},

        pub fn addTimeSource(candidate_time_sources: *CandidateTimeSources, time_source: CandidateTimeSource) void {
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

            init_log.debug("adding time source: {s}", .{time_source.name});
            init_log.debug("  priority: {}", .{time_source.priority});
            init_log.debug("  reference counter: {} - wall clock: {} - per-executor periodic: {}", .{
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
            reference_counter: ReferenceCounter,
        ) void {
            if (candidate_time_source.initialized) return;
            switch (candidate_time_source.initialization) {
                .none => {},
                .simple => |simple| simple(),
                .calibration_required => |calibration_required| calibration_required(reference_counter),
            }
            candidate_time_source.initialized = true;
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

            pub const Tick = kernel.time.wallclock.Tick;
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

    fn getReferenceCounter(time_sources: []CandidateTimeSource) ReferenceCounter {
        const time_source = findAndInitializeTimeSource(time_sources, .{
            .pre_calibrated = true,
            .reference_counter = true,
        }, undefined) orelse @panic("no reference counter found");

        init_log.debug("using reference counter: {s}", .{time_source.name});

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
        }, reference_counter) orelse @panic("no wallclock found");

        init_log.debug("using wallclock: {s}", .{time_source.name});

        const wallclock_impl = time_source.wallclock.?;

        wallclock.globals.readFn = wallclock_impl.readFn;
        wallclock.globals.elapsedFn = wallclock_impl.elapsedFn;

        if (!wallclock_impl.standard_wallclock_source) {
            init_log.warn(
                "wallclock is not the standard wallclock source - setting kernel start time to now",
                .{},
            );
            wallclock.kernel_start = wallclock.read();
            wallclock.kernel_start_type = .time_system_start;
        }
    }

    fn configurePerExecutorPeriodicTimeSource(
        time_sources: []CandidateTimeSource,
        reference_counter: ReferenceCounter,
    ) void {
        const time_source = findAndInitializeTimeSource(time_sources, .{
            .per_executor_periodic = true,
        }, reference_counter) orelse @panic("no per-executor periodic found");

        init_log.debug("using per-executor periodic: {s}", .{time_source.name});

        const per_executor_periodic_impl = time_source.per_executor_periodic.?;

        per_executor_periodic.globals.enableInterruptFn = per_executor_periodic_impl.enableInterruptFn;
    }

    const TimeSourceQuery = struct {
        pre_calibrated: bool = false,

        reference_counter: bool = false,

        wallclock: bool = false,

        per_executor_periodic: bool = false,
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

            if (query.per_executor_periodic and time_source.per_executor_periodic == null) continue;

            if (opt_best_candidate) |best_candidate| {
                if (time_source.priority > best_candidate.priority) opt_best_candidate = time_source;
            } else {
                opt_best_candidate = time_source;
            }
        }

        if (opt_best_candidate) |best_candidate| best_candidate.initialize(reference_counter);

        return opt_best_candidate;
    }

    const init_log = kernel.debug.log.scoped(.init_time);
};

const arch = @import("arch");
const kernel = @import("kernel");

const core = @import("core");
const std = @import("std");
