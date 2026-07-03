// SPDX-License-Identifier: BSD-3-Clause
// SPDX-FileCopyrightText: CascadeOS Contributors

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const core = @import("core");

const x64 = @import("x64.zig");

pub const functions: arch.Functions = .{
    .safeMemcpy = x64.safeMemcpy,

    .executor = .{
        .flushRequestNotify = x64.Executor.flushRequestNotify,
        .sendPanicAllButSelf = x64.Executor.sendPanicAllButSelf,

        .current = .{
            .spinLoopHint = x64.Executor.current.spinLoopHint,
            .halt = x64.Executor.current.halt,
            .disableInterruptsAndHalt = x64.Executor.current.disableInterruptsAndHalt,
            .interruptsEnabled = x64.Executor.current.interruptsEnabled,
            .enableInterrupts = x64.Executor.current.enableInterrupts,
            .disableInterrupts = x64.Executor.current.disableInterrupts,
            .flushCache = x64.Executor.current.flushCache,
            .enableAccessToUserMemory = x64.Executor.current.enableAccessToUserMemory,
            .disableAccessToUserMemory = x64.Executor.current.disableAccessToUserMemory,
        },

        .init = .{
            .prepareBootstrap = x64.Executor.init.prepareBootstrap,
            .prepare = x64.Executor.init.prepare,
            .initialize = x64.Executor.init.initialize,
            .configurePerExecutorSystemFeatures = x64.Executor.init.configurePerExecutorSystemFeatures,
            .initLocalInterruptController = x64.Executor.init.initLocalInterruptController,
        },
    },

    .interrupt = .{
        .from = x64.Interrupt.from,
        .to = x64.Interrupt.to,
        .allocate = x64.Interrupt.allocate,
        .deallocate = x64.Interrupt.deallocate,

        .frame = .{
            .fillContext = x64.Interrupt.Frame.fillContext,
            .getInstructionPointer = x64.Interrupt.Frame.getInstructionPointer,
            .setInstructionPointer = x64.Interrupt.Frame.setInstructionPointer,
        },

        .external = .{
            .from = x64.Interrupt.External.from,
            .eoiType = x64.Interrupt.External.eoiType,
            .route = x64.Interrupt.External.route,
        },

        .init = .{
            .initializeEarlyInterrupts = x64.Interrupt.init.initializeEarlyInterrupts,
            .initializeInterruptRouting = x64.Interrupt.init.initializeInterruptRouting,
            .loadStandardInterruptHandlers = x64.Interrupt.init.loadStandardInterruptHandlers,
        },
    },

    .page_table = .{
        .create = x64.PageTable.create,
        .load = x64.PageTable.load,
        .copyTopLevel = x64.PageTable.copyTopLevel,
        .mapSinglePage = x64.PageTable.mapSinglePage,
        .unmap = x64.PageTable.unmap,
        .changeProtection = x64.PageTable.changeProtection,

        .init = .{
            .sizeOfTopLevelEntry = x64.PageTable.init.sizeOfTopLevelEntry,
            .fillTopLevel = x64.PageTable.init.fillTopLevel,
            .mapToPhysicalRangeAllPageSizes = x64.PageTable.init.mapToPhysicalRangeAllPageSizes,
        },
    },

    .thread = .{
        .create = x64.Thread.create,
        .destroy = x64.Thread.destroy,
        .initialize = x64.Thread.initialize,

        .current = .{
            .enterUserspace = x64.Thread.current.enterUserspace,
        },

        .init = .{
            .initialize = x64.Thread.init.initialize,
        },
    },

    .syscall_frame = .{
        .syscall = x64.syscall.Frame.syscall,
        .arg = x64.syscall.Frame.arg,
    },

    .task = .{
        .initialize = x64.Task.initialize,
        .getCurrent = x64.Task.getCurrent,
        .setCurrent = x64.Task.setCurrent,
        .prepareForScheduling = x64.Task.prepareForScheduling,
        .prepareSwitch = x64.Task.prepareSwitch,
        .performSwitch = x64.Task.performSwitch,
        .performSwitchNoSave = x64.Task.performSwitchNoSave,
        .call = x64.Task.call,
        .callNoSave = x64.Task.callNoSave,
    },

    .pci = .{
        .readU8 = struct {
            fn readPciU8(address: cascade.KernelVirtualAddress) u8 {
                return asm volatile ("movb (%[address]), %[ret]"
                    : [ret] "={al}" (-> u8),
                    : [address] "r" (address.value),
                );
            }
        }.readPciU8,
        .readU16 = struct {
            fn readPciU16(address: cascade.KernelVirtualAddress) u16 {
                return asm volatile ("movw (%[address]), %[ret]"
                    : [ret] "={ax}" (-> u16),
                    : [address] "r" (address.value),
                );
            }
        }.readPciU16,
        .readU32 = struct {
            fn readPciU32(address: cascade.KernelVirtualAddress) u32 {
                return asm volatile ("movl (%[address]), %[ret]"
                    : [ret] "={eax}" (-> u32),
                    : [address] "r" (address.value),
                );
            }
        }.readPciU32,
        .writeU8 = struct {
            fn writePciU8(address: cascade.KernelVirtualAddress, value: u8) void {
                asm volatile ("movb %[value], (%[address])"
                    :
                    : [address] "r" (address.value),
                      [value] "{al}" (value),
                    : .{ .memory = true });
            }
        }.writePciU8,
        .writeU16 = struct {
            fn writePciU16(address: cascade.KernelVirtualAddress, value: u16) void {
                asm volatile ("movw %[value], (%[address])"
                    :
                    : [address] "r" (address.value),
                      [value] "{ax}" (value),
                    : .{ .memory = true });
            }
        }.writePciU16,
        .writeU32 = struct {
            fn writePciU32(address: cascade.KernelVirtualAddress, value: u32) void {
                asm volatile ("movl %[value], (%[address])"
                    :
                    : [address] "r" (address.value),
                      [value] "{eax}" (value),
                    : .{ .memory = true });
            }
        }.writePciU32,
    },

    .port = .{
        .from = x64.Port.from,
        .readU8 = x64.Port.readPortU8,
        .readU16 = x64.Port.readPortU16,
        .readU32 = x64.Port.readPortU32,
        .writeU8 = x64.Port.writePortU8,
        .writeU16 = x64.Port.writePortU16,
        .writeU32 = x64.Port.writePortU32,
    },

    .init = .{
        .getStandardWallclockStartTime = x64.init.getStandardWallclockStartTime,
        .registerArchitecturalTimeSources = x64.init.registerArchitecturalTimeSources,
        .tryGetSerialOutput = x64.init.tryGetSerialOutput,
        .captureSystemInformation = x64.init.captureSystemInformation,
        .configureGlobalSystemFeatures = x64.init.configureGlobalSystemFeatures,
    },
};

const size_of_canonical_region: core.Size = .from(128, .tib); // TODO: 5 level paging

pub const decls: arch.Decls = .{
    .kernel_memory_range = .from(
        cascade.VirtualAddress.from(0xffff800000000000),
        size_of_canonical_region
            // exclude the last page of memory, this prevents boundary conditions
            .subtract(x64.PageTable.small_page_size),
    ),

    .user_memory_range = .from(
        cascade.VirtualAddress.zero
            // exclude the first page of memory so that a null pointer is not a valid user address
            .moveForward(x64.PageTable.small_page_size),
        size_of_canonical_region
            // exclude the first page of memory so that a null pointer is not a valid user address
            .subtract(x64.PageTable.small_page_size)
            // exclude the last page of memory, this prevents boundary conditions like a syscall instruction at the end of the last page
            // causing a general protection fault in the kernel on sysret as the return address is non-canonical
            .subtract(x64.PageTable.small_page_size),
    ),

    .cfi_prevent_unwinding =
    \\.cfi_sections .debug_frame
    \\.cfi_undefined rip
    \\
    ,

    .Executor = x64.Executor,

    .ExecutorId = x64.Executor.Id,

    .Interrupt = x64.Interrupt,

    .InterruptFrame = x64.Interrupt.Frame,

    .ExternalInterrupt = x64.Interrupt.External,

    .PageTable = x64.PageTable,

    .standard_page_size = x64.PageTable.small_page_size,

    .largest_page_size = x64.PageTable.large_page_size,

    .Thread = x64.Thread,

    .SyscallFrame = x64.syscall.Frame,

    .Task = x64.Task,

    .Port = x64.Port,

    .CaptureSystemInformationOptions = x64.init.CaptureSystemInformationOptions,
};
