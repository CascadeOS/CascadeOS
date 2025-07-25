// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

/// Returns the PHYSICAL address of the RSDP structure via *out_rsdp_address.
export fn uacpi_kernel_get_rsdp(out_rsdp_address: *core.PhysicalAddress) uacpi.Status {
    log.verbose("uacpi_kernel_get_rsdp called", .{});

    const address = kernel.boot.rsdp() orelse return uacpi.Status.not_found;

    switch (address) {
        .physical => |addr| out_rsdp_address.* = addr,
        .virtual => |addr| out_rsdp_address.* =
            kernel.mem.physicalFromDirectMap(addr) catch return .internal_error,
    }

    return .ok;
}

/// Open a PCI device at 'address' for reading & writing.
///
/// The handle returned via 'out_handle' is used to perform IO on the configuration space of the device.
///
/// Note that this must be able to open any arbitrary PCI device, not just those detected during kernel PCI enumeration.
export fn uacpi_kernel_pci_device_open(
    address: kernel.pci.Address,
    out_handle: **volatile kernel.pci.Function,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_device_open called with address {f}", .{address});

    out_handle.* = kernel.pci.getFunction(address) orelse return uacpi.Status.not_found;
    return .ok;
}

export fn uacpi_kernel_pci_device_close(handle: *anyopaque) void {
    log.verbose("uacpi_kernel_pci_device_close called", .{});
    _ = handle;
}

/// Read the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_read8(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: *u8,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_read8 called", .{});

    value.* = function.read(u8, offset);

    return .ok;
}

/// Read the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_read16(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: *u16,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_read16 called", .{});

    value.* = function.read(u16, offset);

    return .ok;
}

/// Read the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_read32(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: *u32,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_read32 called", .{});

    value.* = function.read(u32, offset);

    return .ok;
}

/// Write the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_write8(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: u8,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_write8 called", .{});

    function.write(u8, offset, value);

    return .ok;
}

/// Write the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_write16(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: u16,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_write16 called", .{});

    function.write(u16, offset, value);

    return .ok;
}

/// Write the configuration space of a previously open PCI device.
export fn uacpi_kernel_pci_write32(
    function: *volatile kernel.pci.Function,
    offset: usize,
    value: u32,
) uacpi.Status {
    log.verbose("uacpi_kernel_pci_write32 called", .{});

    function.write(u32, offset, value);

    return .ok;
}

/// Map a SystemIO address at [base, base + len) and return a kernel-implemented handle that can be used for reading
/// and writing the IO range.
///
/// NOTE: The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_map(base: u64, len: usize, out_handle: **anyopaque) uacpi.Status {
    log.verbose("uacpi_kernel_io_map called", .{});

    _ = len;

    out_handle.* = @ptrFromInt(base);
    return .ok;
}

export fn uacpi_kernel_io_unmap(handle: *anyopaque) void {
    log.verbose("uacpi_kernel_io_unmap called", .{});
    _ = handle;
}

/// Read the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_read8(
    handle: *anyopaque,
    offset: usize,
    value: *u8,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_read8 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);

    value.* = kernel.arch.io.readPort(u8, port) catch return .invalid_argument;
    return .ok;
}

/// Read the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_read16(
    handle: *anyopaque,
    offset: usize,
    value: *u16,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_read16 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);
    std.debug.assert(std.mem.isAligned(port, @sizeOf(u16)));

    value.* = kernel.arch.io.readPort(u16, port) catch return .invalid_argument;
    return .ok;
}

/// Read the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_read32(
    handle: *anyopaque,
    offset: usize,
    value: *u32,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_read32 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);
    std.debug.assert(std.mem.isAligned(port, @sizeOf(u32)));

    value.* = kernel.arch.io.readPort(u32, port) catch return .invalid_argument;
    return .ok;
}

/// Write the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_write8(
    handle: *anyopaque,
    offset: usize,
    value: u8,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_write8 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);

    kernel.arch.io.writePort(u8, port, value) catch return .invalid_argument;
    return .ok;
}

/// Write the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_write16(
    handle: *anyopaque,
    offset: usize,
    value: u16,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_write16 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);
    std.debug.assert(std.mem.isAligned(port, @sizeOf(u16)));

    kernel.arch.io.writePort(u16, port, value) catch return .invalid_argument;
    return .ok;
}

/// Write the IO range mapped via `uacpi_kernel_io_map` at a 0-based 'offset' within the range.
///
/// The x86 architecture uses the in/out family of instructions to access the SystemIO address space.
export fn uacpi_kernel_io_write32(
    handle: *anyopaque,
    offset: usize,
    value: u32,
) uacpi.Status {
    log.verbose("uacpi_kernel_io_write32 called", .{});

    // TODO: only supports x86 ports

    const port: u16 = @intCast(@intFromPtr(handle) + offset);
    std.debug.assert(std.mem.isAligned(port, @sizeOf(u32)));

    kernel.arch.io.writePort(u32, port, value) catch return .invalid_argument;
    return .ok;
}

/// Map a physical memory range starting at 'addr' with length 'len', and return a virtual address that can be used to
/// access it.
///
/// NOTE: 'addr' may be misaligned, in this case the host is expected to round it down to the nearest page-aligned
/// boundary and map that, while making sure that at least 'len' bytes are still mapped starting at 'addr'.
///
/// The return value preserves the misaligned offset.
///
///       Example for uacpi_kernel_map(0x1ABC, 0xF00):
///           1. Round down the 'addr' we got to the nearest page boundary.
///              Considering a PAGE_SIZE of 4096 (or 0x1000), 0x1ABC rounded down is 0x1000, offset within the page is
///              0x1ABC - 0x1000 => 0xABC
///           2. Requested 'len' is 0xF00 bytes, but we just rounded the address down by 0xABC bytes, so add those on
///              top. 0xF00 + 0xABC => 0x19BC
///           3. Round up the final 'len' to the nearest PAGE_SIZE boundary, in this case 0x19BC is 0x2000 bytes
///              (2 pages if PAGE_SIZE is 4096)
///           4. Call the VMM to map the aligned address 0x1000 (from step 1) with length 0x2000 (from step 3).
///              Let's assume the returned virtual address for the mapping is 0xF000.
///           5. Add the original offset within page 0xABC (from step 1) to the resulting virtual address
///              0xF000 + 0xABC => 0xFABC. Return it to uACPI.
export fn uacpi_kernel_map(addr: core.PhysicalAddress, len: usize) [*]u8 {
    log.verbose("uacpi_kernel_map called", .{});

    _ = len;

    return kernel.mem.directMapFromPhysical(addr).toPtr([*]u8);
}

/// Unmap a virtual memory range at 'addr' with a length of 'len' bytes.
///
/// NOTE: 'addr' may be misaligned, see the comment above 'uacpi_kernel_map'.
///       Similar steps to uacpi_kernel_map can be taken to retrieve the virtual address originally returned by the VMM
///       for this mapping as well as its true length.
export fn uacpi_kernel_unmap(addr: [*]u8, len: usize) void {
    log.verbose("uacpi_kernel_unmap called", .{});

    _ = addr;
    _ = len;
}

/// Allocate a block of memory of 'size' bytes.
/// The contents of the allocated memory are unspecified.
export fn uacpi_kernel_alloc(size: usize) ?[*]u8 {
    log.verbose("uacpi_kernel_alloc called", .{});

    const buf = kernel.mem.heap.allocator.alloc(u8, size) catch return null;
    return buf.ptr;
}

/// Free a previously allocated memory block.
///
/// 'mem' might be a NULL pointer. In this case, the call is assumed to be a no-op.
export fn uacpi_kernel_free(opt_mem: ?[*]u8) void {
    log.verbose("uacpi_kernel_free called", .{});
    kernel.mem.heap.freeWithNoSize(opt_mem orelse return);
}

export fn uacpi_kernel_log(uacpi_log_level: uacpi.LogLevel, c_msg: [*:0]const u8) void {
    const uacpi_log = kernel.debug.log.scoped(.uacpi);

    switch (uacpi_log_level) {
        inline else => |level| {
            const kernel_log_level: kernel.debug.log.Level = comptime switch (level) {
                .DEBUG => .verbose, // DEBUG is the most verbose in uACPI
                .TRACE, .INFO => .debug,
                .WARN => .warn,
                .ERROR => .err,
            };

            if (!uacpi_log.levelEnabled(kernel_log_level)) return;

            const full_msg = std.mem.sliceTo(c_msg, 0);

            const msg = if (full_msg.len > 0 and full_msg[full_msg.len - 1] == '\n')
                full_msg[0 .. full_msg.len - 1]
            else
                full_msg;

            switch (kernel_log_level) {
                .verbose => uacpi_log.verbose("{s}", .{msg}),
                .debug => uacpi_log.debug("{s}", .{msg}),
                .info => @compileError("NO INFO LOGS"),
                .warn => uacpi_log.warn("{s}", .{msg}),
                .err => uacpi_log.err("{s}", .{msg}),
            }
        },
    }
}

/// Returns the number of nanosecond ticks elapsed since boot, strictly monotonic.
export fn uacpi_kernel_get_nanoseconds_since_boot() u64 {
    log.verbose("uacpi_kernel_get_nanoseconds_since_boot called", .{});
    return kernel.time.wallclock.elapsed(.zero, kernel.time.wallclock.read()).value;
}

/// Spin for N microseconds.
export fn uacpi_kernel_stall(usec: u8) void {
    log.verbose("uacpi_kernel_stall called", .{});

    const start = kernel.time.wallclock.read();

    const duration: core.Duration = .from(usec, .microsecond);

    while (kernel.time.wallclock.elapsed(start, kernel.time.wallclock.read()).lessThan(duration)) {
        kernel.arch.spinLoopHint();
    }
}

/// Sleep for N milliseconds.
export fn uacpi_kernel_sleep(msec: u64) void {
    log.verbose("uacpi_kernel_sleep called", .{});

    std.debug.panic("uacpi_kernel_sleep(msec={})", .{msec});
}

/// Create an opaque non-recursive kernel mutex object.
export fn uacpi_kernel_create_mutex() *kernel.sync.Mutex {
    log.verbose("uacpi_kernel_create_mutex called", .{});

    const mutex = kernel.mem.heap.allocator.create(kernel.sync.Mutex) catch unreachable;
    mutex.* = .{};
    return mutex;
}

/// Free a opaque non-recursive kernel mutex object.
export fn uacpi_kernel_free_mutex(mutex: *kernel.sync.Mutex) void {
    log.verbose("uacpi_kernel_free_mutex called", .{});

    kernel.mem.heap.allocator.destroy(mutex);
}

/// Create/free an opaque kernel (semaphore-like) event object.
export fn uacpi_kernel_create_event() *anyopaque {
    log.verbose("uacpi_kernel_create_event called", .{});

    log.warn("uacpi_kernel_create_event called with dummy implementation", .{});

    const static = struct {
        var value: std.atomic.Value(usize) = .init(1);
    };

    return @ptrFromInt(static.value.fetchAdd(1, .monotonic));
}

/// Free a previously allocated kernel (semaphore-like) event object.
export fn uacpi_kernel_free_event(handle: *anyopaque) void {
    log.verbose("uacpi_kernel_free_event called", .{});

    std.debug.panic("uacpi_kernel_free_event(handle={})", .{handle});
}

/// Returns a unique identifier of the currently executing thread.
///
/// The returned thread id cannot be UACPI_THREAD_ID_NONE.
export fn uacpi_kernel_get_thread_id() usize {
    log.verbose("uacpi_kernel_get_thread_id called", .{});

    return @intFromPtr(kernel.Task.getCurrent());
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
    log.verbose("uacpi_kernel_acquire_mutex called", .{});

    const current_task = kernel.Task.getCurrent();

    switch (timeout) {
        .none => if (!mutex.tryLock(current_task)) return .timeout,
        .infinite => mutex.lock(current_task),
        else => @panic("mutex timeout lock not implemented"),
    }

    return .ok;
}

export fn uacpi_kernel_release_mutex(mutex: *kernel.sync.Mutex) void {
    log.verbose("uacpi_kernel_release_mutex called", .{});

    mutex.unlock(kernel.Task.getCurrent());
}

/// Try to wait for an event (counter > 0) with a millisecond timeout.
///
/// The internal counter is decremented by 1 if wait was successful.
///
/// A successful wait is indicated by returning UACPI_TRUE.
export fn uacpi_kernel_wait_for_event(handle: *anyopaque, timeout: uacpi.Timeout) bool {
    log.verbose("uacpi_kernel_wait_for_event called", .{});

    std.debug.panic(
        "uacpi_kernel_wait_for_event(handle={}, timeout={})",
        .{ handle, timeout },
    );
}

/// Signal the event object by incrementing its internal counter by 1.
///
/// This function may be used in interrupt contexts.
export fn uacpi_kernel_signal_event(handle: *anyopaque) void {
    log.verbose("uacpi_kernel_signal_event called", .{});

    std.debug.panic("uacpi_kernel_signal_event(handle={})", .{handle});
}

/// Reset the event counter to 0.
export fn uacpi_kernel_reset_event(handle: *anyopaque) void {
    log.verbose("uacpi_kernel_reset_event called", .{});

    std.debug.panic("uacpi_kernel_reset_event(handle={})", .{handle});
}

/// Handle a firmware request.
///
/// Currently either a Breakpoint or Fatal operators.
export fn uacpi_kernel_handle_firmware_request(request: *const uacpi.FirmwareRequest) uacpi.Status {
    log.verbose("uacpi_kernel_handle_firmware_request called", .{});

    std.debug.panic(
        "uacpi_kernel_handle_firmware_request(request={})",
        .{request},
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
    log.verbose("uacpi_kernel_install_interrupt_handler called", .{});

    const HandlerWrapper = struct {
        fn HandlerWrapper(
            _: *kernel.Task,
            _: kernel.arch.interrupts.InterruptFrame,
            _handler: ?*anyopaque,
            _ctx: ?*anyopaque,
        ) void {
            const inner_handler: uacpi.RawInterruptHandler = @ptrCast(@alignCast(_handler));
            _ = inner_handler(@ptrCast(_ctx)); // FIXME: should we do something with the return value?
        }
    }.HandlerWrapper;

    const current_task = kernel.Task.getCurrent();

    const interrupt = kernel.arch.interrupts.allocateInterrupt(
        current_task,
        HandlerWrapper,
        @constCast(handler),
        ctx,
    ) catch |err| {
        log.err("failed to allocate interrupt: {}", .{err});
        return .internal_error;
    };

    kernel.arch.interrupts.routeInterrupt(irq, interrupt) catch |err| {
        kernel.arch.interrupts.deallocateInterrupt(current_task, interrupt);

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
    log.verbose("uacpi_kernel_uninstall_interrupt_handler called", .{});

    const interrupt: kernel.arch.interrupts.Interrupt = @enumFromInt(@intFromPtr(irq_handle));
    kernel.arch.interrupts.deallocateInterrupt(kernel.Task.getCurrent(), interrupt);

    return .ok;
}

/// Create a kernel spinlock object.
///
/// Unlike other types of locks, spinlocks may be used in interrupt contexts.
export fn uacpi_kernel_create_spinlock() *kernel.sync.TicketSpinLock {
    log.verbose("uacpi_kernel_create_spinlock called", .{});

    const lock = kernel.mem.heap.allocator.create(kernel.sync.TicketSpinLock) catch unreachable;
    lock.* = .{};
    return lock;
}

/// Free a kernel spinlock object.
///
/// Unlike other types of locks, spinlocks may be used in interrupt contexts.
export fn uacpi_kernel_free_spinlock(spinlock: *kernel.sync.TicketSpinLock) void {
    log.verbose("uacpi_kernel_free_spinlock called", .{});

    kernel.mem.heap.allocator.destroy(spinlock);
}

/// Lock a spinlock.
///
/// These are expected to disable interrupts, returning the previous state of cpu flags, that can be used to
/// possibly re-enable interrupts if they were enabled before.
///
/// Note that lock is infalliable.
export fn uacpi_kernel_lock_spinlock(spinlock: *kernel.sync.TicketSpinLock) uacpi.CpuFlags {
    log.verbose("uacpi_kernel_lock_spinlock called", .{});

    spinlock.lock(kernel.Task.getCurrent());
    return 0;
}

export fn uacpi_kernel_unlock_spinlock(spinlock: *kernel.sync.TicketSpinLock, cpu_flags: uacpi.CpuFlags) void {
    log.verbose("uacpi_kernel_unlock_spinlock called", .{});

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
    log.verbose("uacpi_kernel_schedule_work called", .{});

    std.debug.panic(
        "uacpi_kernel_schedule_work(work_type={}, handler={}, ctx={})",
        .{ work_type, handler, ctx },
    );
}

/// Waits for two types of work to finish:
/// 1. All in-flight interrupts installed via uacpi_kernel_install_interrupt_handler
/// 2. All work scheduled via uacpi_kernel_schedule_work
///
/// Note that the waits must be done in this order specifically.
export fn uacpi_kernel_wait_for_work_completion() uacpi.Status {
    log.verbose("uacpi_kernel_wait_for_work_completion called", .{});

    @panic("uacpi_kernel_wait_for_work_completion()");
}

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");
const uacpi = @import("uacpi.zig");
const log = kernel.debug.log.scoped(.uacpi_kernel_api);
