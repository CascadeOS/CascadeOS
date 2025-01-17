// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2025 Lee Cannon <leecannon@leecannon.xyz>

/// Returns the PHYSICAL address of the RSDP structure via *out_rsdp_address.
export fn uacpi_kernel_get_rsdp(out_rsdp_address: *core.PhysicalAddress) uacpi.Status {
    const address = kernel.boot.rsdp() orelse return uacpi.Status.not_found;

    switch (address) {
        .physical => |addr| out_rsdp_address.* = addr,
        .virtual => |addr| out_rsdp_address.* =
            kernel.vmm.physicalFromDirectMap(addr) catch return .internal_error,
    }

    return .ok;
}

/// Open a PCI device at 'address' for reading & writing.
///
/// The handle returned via 'out_handle' is used to perform IO on the configuration space of the device.
export fn uacpi_kernel_pci_device_open(
    address: kernel.pci.Address,
    out_handle: **kernel.pci.PciFunction,
) uacpi.Status {
    out_handle.* = kernel.pci.getFunction(address) orelse return uacpi.Status.not_found;
    return .ok;
}

export fn uacpi_kernel_pci_device_close(handle: *anyopaque) void {
    _ = handle;
}

/// Read the configuration space of a previously open PCI device.
///
/// NOTE:
/// Since PCI registers are 32 bits wide this must be able to handle e.g. a 1-byte access by reading at the nearest
/// 4-byte aligned offset below, then masking the value to select the target byte.
export fn uacpi_kernel_pci_read(
    device: *kernel.pci.PciFunction,
    offset: usize,
    byte_width: uacpi.ByteWidth,
    value: *u64,
) uacpi.Status {
    const address = device.config_space_address.moveForward(.from(offset, .byte));

    value.* = switch (byte_width) {
        .one => address.toPtr(*const volatile u8).*,
        .two => address.toPtr(*const volatile u16).*,
        .four => address.toPtr(*const volatile u32).*,
    };

    return .ok;
}

/// Write the configuration space of a previously open PCI device.
///
/// NOTE:
/// Since PCI registers are 32 bits wide this must be able to handle e.g. a 1-byte access by reading at the nearest
/// 4-byte aligned offset below, then masking the value to select the target byte.
export fn uacpi_kernel_pci_write(
    device: *kernel.pci.PciFunction,
    offset: usize,
    byte_width: uacpi.ByteWidth,
    value: u64,
) uacpi.Status {
    const address = device.config_space_address.moveForward(.from(offset, .byte));

    switch (byte_width) {
        .one => address.toPtr(*volatile u8).* = @truncate(value),
        .two => address.toPtr(*volatile u16).* = @truncate(value),
        .four => address.toPtr(*volatile u32).* = @truncate(value),
    }

    return .ok;
}

/// Map a SystemIO address at [base, base + len) and return a kernel-implemented handle that can be used for reading
/// and writing the IO range.
export fn uacpi_kernel_io_map(base: u64, len: usize, out_handle: **anyopaque) uacpi.Status {
    _ = len;
    out_handle.* = @ptrFromInt(base);
    return .ok;
}

export fn uacpi_kernel_io_unmap(handle: *anyopaque) void {
    _ = handle;
}

/// Read the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// NOTE:
/// You are NOT allowed to break e.g. a 4-byte access into four 1-byte accesses. Hardware ALWAYS expects accesses to
/// be of the exact width.
export fn uacpi_kernel_io_read(
    handle: *anyopaque,
    offset: usize,
    byte_width: uacpi.ByteWidth,
    value: *u64,
) uacpi.Status {
    _ = offset;
    const port: u16 = @intCast(@intFromPtr(handle)); // IO ports are 16-bit
    switch (byte_width) {
        .one => value.* = kernel.arch.io.readPort(u8, port) catch return .invalid_argument,
        .two => value.* = kernel.arch.io.readPort(u16, port) catch return .invalid_argument,
        .four => value.* = kernel.arch.io.readPort(u32, port) catch return .invalid_argument,
    }
    return .ok;
}

/// Write the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// NOTE:
/// You are NOT allowed to break e.g. a 4-byte access into four 1-byte accesses. Hardware ALWAYS expects accesses to
/// be of the exact width.
export fn uacpi_kernel_io_write(
    handle: *anyopaque,
    offset: usize,
    byte_width: uacpi.ByteWidth,
    value: u64,
) uacpi.Status {
    _ = offset;
    const port: u16 = @intCast(@intFromPtr(handle)); // IO ports are 16-bit
    switch (byte_width) {
        .one => kernel.arch.io.writePort(u8, port, @truncate(value)) catch return .invalid_argument,
        .two => kernel.arch.io.writePort(u16, port, @truncate(value)) catch return .invalid_argument,
        .four => kernel.arch.io.writePort(u32, port, @truncate(value)) catch return .invalid_argument,
    }

    return .ok;
}

export fn uacpi_kernel_map(addr: core.PhysicalAddress, len: usize) [*]u8 {
    _ = len;
    return kernel.vmm.nonCachedDirectMapFromPhysical(addr).toPtr([*]u8);
}

export fn uacpi_kernel_unmap(addr: [*]u8, len: usize) void {
    _ = addr;
    _ = len;
}

/// Allocate a block of memory of 'size' bytes.
/// The contents of the allocated memory are unspecified.
export fn uacpi_kernel_alloc(size: usize) ?[*]u8 {
    const allocation = kernel.heap.allocate(
        size,
        kernel.Task.getCurrent(),
    ) catch return null;
    return allocation.address.toPtr([*]u8);
}

/// Free a previously allocated memory block.
///
/// 'mem' might be a NULL pointer. In this case, the call is assumed to be a no-op.
export fn uacpi_kernel_free(opt_mem: ?[*]u8) void {
    const mem = opt_mem orelse return;
    kernel.heap.deallocateBase(.fromPtr(mem), kernel.Task.getCurrent());
}

export fn uacpi_kernel_log(uacpi_log_level: uacpi.LogLevel, c_msg: [*:0]const u8) void {
    switch (uacpi_log_level) {
        inline else => |level| {
            const kernel_log_level: std.log.Level = comptime switch (level) {
                .DEBUG, .TRACE, .INFO => .debug,
                .WARN => .warn,
                .ERROR => .err,
            };

            if (!log.levelEnabled(kernel_log_level)) return;

            const full_msg = std.mem.sliceTo(c_msg, 0);

            const msg = if (full_msg.len > 0 and full_msg[full_msg.len - 1] == '\n')
                full_msg[0 .. full_msg.len - 1]
            else
                full_msg;

            switch (kernel_log_level) {
                .debug => log.debug("{s}", .{msg}),
                .info => @compileError("NO INFO LOGS"),
                .warn => log.warn("{s}", .{msg}),
                .err => log.err("{s}", .{msg}),
            }
        },
    }
}

/// Returns the number of nanosecond ticks elapsed since boot, strictly monotonic.
export fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
    return kernel.time.wallclock.elapsed(.zero, kernel.time.wallclock.read()).value;
}

/// Spin for N microseconds.
export fn uacpi_kernel_stall(usec: u8) void {
    const start = kernel.time.wallclock.read();

    const duration: core.Duration = .from(usec, .microsecond);

    while (kernel.time.wallclock.elapsed(start, kernel.time.wallclock.read()).lessThan(duration)) {
        kernel.arch.spinLoopHint();
    }
}

/// Sleep for N milliseconds.
export fn uacpi_kernel_sleep(msec: u64) void {
    core.panicFmt("uacpi_kernel_sleep(msec={})", .{msec}, null);
}

/// Create an opaque non-recursive kernel mutex object.
export fn uacpi_kernel_create_mutex() *kernel.sync.Mutex {
    const mutex = kernel.heap.allocator.create(kernel.sync.Mutex) catch unreachable;
    mutex.* = .{};
    return mutex;
}

/// Free a opaque non-recursive kernel mutex object.
export fn uacpi_kernel_free_mutex(mutex: *kernel.sync.Mutex) void {
    kernel.heap.allocator.destroy(mutex);
}

/// Create/free an opaque kernel (semaphore-like) event object.
export fn uacpi_kernel_create_event() *anyopaque {
    log.warn("uacpi_kernel_create_event called with dummy implementation", .{});

    const static = struct {
        var value: std.atomic.Value(usize) = .init(1);
    };

    return @ptrFromInt(static.value.fetchAdd(1, .acquire));
}

/// Free a previously allocated kernel (semaphore-like) event object.
export fn uacpi_kernel_free_event(handle: *anyopaque) void {
    core.panicFmt("uacpi_kernel_free_event(handle={})", .{handle}, null);
}

/// Returns a unique identifier of the currently executing thread.
///
/// The returned thread id cannot be UACPI_THREAD_ID_NONE.
export fn uacpi_kernel_get_thread_id() kernel.Task.Id {
    return kernel.Task.getCurrent().id;
}

/// Try to acquire the mutex with a millisecond timeout.
///
/// The timeout value has the following meanings:
/// - `.none` - Attempt to acquire the mutex once, in a non-blocking manner
/// - `.infinite` - Infinite wait, block until the mutex is acquired
/// - else - Attempt to acquire the mutex for at least 'timeout' milliseconds
///
/// The following are possible return values:
/// 1. UACPI_STATUS_OK - successful acquire operation
/// 2. UACPI_STATUS_TIMEOUT - timeout reached while attempting to acquire (or the single attempt to acquire was not
///                           successful for calls with timeout=.none)
/// 3. Any other value - signifies a host internal error and is treated as such
export fn uacpi_kernel_acquire_mutex(mutex: *kernel.sync.Mutex, timeout: uacpi.Timeout) uacpi.Status {
    const current_task = kernel.Task.getCurrent();

    switch (timeout) {
        .none => core.panic("mutex try lock not implemented", null),
        .infinite => mutex.lock(current_task),
        else => core.panic("mutex timeout lock not implemented", null),
    }

    return .ok;
}

export fn uacpi_kernel_release_mutex(mutex: *kernel.sync.Mutex) void {
    mutex.unlock(kernel.Task.getCurrent());
}

/// Try to wait for an event (counter > 0) with a millisecond timeout.
///
/// The internal counter is decremented by 1 if wait was successful.
///
/// A successful wait is indicated by returning UACPI_TRUE.
export fn uacpi_kernel_wait_for_event(handle: *anyopaque, timeout: uacpi.Timeout) bool {
    core.panicFmt(
        "uacpi_kernel_wait_for_event(handle={}, timeout={})",
        .{ handle, timeout },
        null,
    );
}

/// Signal the event object by incrementing its internal counter by 1.
///
/// This function may be used in interrupt contexts.
export fn uacpi_kernel_signal_event(handle: *anyopaque) void {
    core.panicFmt("uacpi_kernel_signal_event(handle={})", .{handle}, null);
}

/// Reset the event counter to 0.
export fn uacpi_kernel_reset_event(handle: *anyopaque) void {
    core.panicFmt("uacpi_kernel_reset_event(handle={})", .{handle}, null);
}

/// Handle a firmware request.
///
/// Currently either a Breakpoint or Fatal operators.
export fn uacpi_kernel_handle_firmware_request(request: *const uacpi.FirmwareRequest) uacpi.Status {
    core.panicFmt(
        "uacpi_kernel_handle_firmware_request(request={})",
        .{request},
        null,
    );
}

/// Install an interrupt handler at 'irq', 'ctx' is passed to the provided handler for every invocation.
///
/// 'out_irq_handle' is set to a kernel-implemented value that can be used to refer to this handler from other API.
export fn uacpi_kernel_install_interrupt_handler(
    irq: u32,
    handler: uacpi.RawInterruptHandler,
    ctx: *anyopaque,
    out_irq_handle: **anyopaque,
) uacpi.Status {
    const HandlerWrapper = struct {
        fn HandlerWrapper(
            _: *kernel.Task,
            _: *kernel.arch.interrupts.InterruptFrame,
            _handler: ?*anyopaque,
            _ctx: ?*anyopaque,
        ) void {
            const inner_handler: uacpi.RawInterruptHandler = @ptrCast(@alignCast(_handler));
            _ = inner_handler(@ptrCast(_ctx)); // FIXME: should we do something with the return value?
        }
    }.HandlerWrapper;

    const interrupt = kernel.arch.interrupts.allocateInterrupt(
        HandlerWrapper,
        @constCast(handler),
        ctx,
    ) catch |err| {
        log.err("failed to allocate interrupt: {}", .{err});
        return .internal_error;
    };

    kernel.arch.interrupts.routeInterrupt(irq, interrupt) catch |err| {
        kernel.arch.interrupts.deallocateInterrupt(interrupt);

        log.err("failed to route interrupt: {}", .{err});
        return .internal_error;
    };

    out_irq_handle.* = @ptrFromInt(@intFromEnum(interrupt));

    return .ok;
}

/// Uninstall an interrupt handler.
///
/// 'irq_handle' is the value returned via 'out_irq_handle' during installation.
export fn uacpi_kernel_uninstall_interrupt_handler(
    _: uacpi.RawInterruptHandler,
    irq_handle: *anyopaque,
) uacpi.Status {
    const interrupt: kernel.arch.interrupts.Interrupt = @enumFromInt(@intFromPtr(irq_handle));
    kernel.arch.interrupts.deallocateInterrupt(interrupt);

    return .ok;
}

/// Create a kernel spinlock object.
///
/// Unlike other types of locks, spinlocks may be used in interrupt contexts.
export fn uacpi_kernel_create_spinlock() *kernel.sync.TicketSpinLock {
    const lock = kernel.heap.allocator.create(kernel.sync.TicketSpinLock) catch unreachable;
    lock.* = .{};
    return lock;
}

/// Free a kernel spinlock object.
///
/// Unlike other types of locks, spinlocks may be used in interrupt contexts.
export fn uacpi_kernel_free_spinlock(spinlock: *kernel.sync.TicketSpinLock) void {
    kernel.heap.allocator.destroy(spinlock);
}

/// Lock a spinlock.
///
/// These are expected to disable interrupts, returning the previous state of cpu flags, that can be used to
/// possibly re-enable interrupts if they were enabled before.
///
/// Note that lock is infalliable.
export fn uacpi_kernel_lock_spinlock(spinlock: *kernel.sync.TicketSpinLock) uacpi.CpuFlags {
    spinlock.lock(kernel.Task.getCurrent());
    return 0;
}

export fn uacpi_kernel_unlock_spinlock(spinlock: *kernel.sync.TicketSpinLock, cpu_flags: uacpi.CpuFlags) void {
    _ = cpu_flags;
    spinlock.unlock(kernel.Task.getCurrent());
}

/// Schedules deferred work for execution.
///
/// Might be invoked from an interrupt context.
export fn uacpi_kernel_schedule_work(
    work_type: uacpi.WorkType,
    handler: uacpi.WorkHandler,
    ctx: *anyopaque,
) uacpi.Status {
    core.panicFmt(
        "uacpi_kernel_schedule_work(work_type={}, handler={}, ctx={})",
        .{ work_type, handler, ctx },
        null,
    );
}

/// Waits for two types of work to finish:
/// 1. All in-flight interrupts installed via uacpi_kernel_install_interrupt_handler
/// 2. All work scheduled via uacpi_kernel_schedule_work
///
/// Note that the waits must be done in this order specifically.
export fn uacpi_kernel_wait_for_work_completion() uacpi.Status {
    core.panic("uacpi_kernel_wait_for_work_completion()", null);
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const uacpi = @import("uacpi.zig");
const log = kernel.debug.log.scoped(.uacpi);
