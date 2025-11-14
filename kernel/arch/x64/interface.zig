// SPDX-License-Identifier: LicenseRef-NON-AI-MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");

const arch = @import("arch");
const cascade = @import("cascade");
const Task = cascade.Task;
const core = @import("core");

const x64 = @import("x64.zig");

pub const functions: arch.Functions = .{
    .getCurrentExecutor = struct {
        inline fn getCurrentExecutor() *cascade.Executor {
            return @ptrFromInt(x64.registers.KERNEL_GS_BASE.read());
        }
    }.getCurrentExecutor,

    .spinLoopHint = x64.instructions.pause,
    .halt = x64.instructions.halt,

    .interrupts = .{
        .disableAndHalt = x64.instructions.disableInterruptsAndHalt,
        .areEnabled = x64.instructions.interruptsEnabled,
        .enable = x64.instructions.enableInterrupts,
        .disable = x64.instructions.disableInterrupts,

        .eoi = x64.apic.eoi,
        .sendPanicIPI = x64.apic.sendPanicIPI,
        .sendFlushIPI = x64.apic.sendFlushIPI,

        .allocateInterrupt = x64.interrupts.Interrupt.allocate,
        .deallocateInterrupt = x64.interrupts.Interrupt.deallocate,
        .routeInterrupt = x64.interrupts.Interrupt.route,

        .createStackIterator = struct {
            fn createStackIterator(
                interrupt_frame: *const x64.interrupts.InterruptFrame,
            ) std.debug.StackIterator {
                return .init(null, interrupt_frame.rbp);
            }
        }.createStackIterator,
        .instructionPointer = struct {
            fn instructionPointer(interrupt_frame: *const x64.interrupts.InterruptFrame) usize {
                return interrupt_frame.rip;
            }
        }.instructionPointer,

        .init = .{
            .initializeEarlyInterrupts = x64.interrupts.init.initializeEarlyInterrupts,
            .initializeInterruptRouting = x64.interrupts.init.initializeInterruptRouting,
            .loadStandardInterruptHandlers = x64.interrupts.init.loadStandardInterruptHandlers,
        },
    },

    .paging = .{
        .createPageTable = x64.paging.PageTable.create,

        .loadPageTable = struct {
            fn loadPageTable(current_task: Task.Current, physical_frame: cascade.mem.phys.Frame) void {
                _ = current_task;
                x64.registers.Cr3.writeAddress(physical_frame.baseAddress());
            }
        }.loadPageTable,

        .copyTopLevelIntoPageTable = struct {
            fn copyTopLevelIntoPageTable(
                page_table: *x64.paging.PageTable,
                current_task: Task.Current,
                target_page_table: *x64.paging.PageTable,
            ) void {
                _ = current_task;
                if (core.is_debug) std.debug.assert(page_table != target_page_table);
                @memcpy(&target_page_table.entries, &page_table.entries);
            }
        }.copyTopLevelIntoPageTable,

        .mapSinglePage = x64.paging.PageTable.map4KiB,
        .unmap = x64.paging.PageTable.unmap,
        .changeProtection = x64.paging.PageTable.changeProtection,
        .flushCache = x64.paging.flushCache,
        .enableAccessToUserMemory = x64.instructions.enableAccessToUserMemory,
        .disableAccessToUserMemory = x64.instructions.disableAccessToUserMemory,

        .init = .{
            .sizeOfTopLevelEntry = x64.paging.PageTable.sizeOfTopLevelEntry,
            .fillTopLevel = x64.paging.PageTable.init.fillTopLevel,
            .mapToPhysicalRangeAllPageSizes = x64.paging.PageTable.init.mapToPhysicalRangeAllPageSizes,
        },
    },

    .scheduling = .{
        .beforeSwitchTask = x64.scheduling.beforeSwitchTask,
        .switchTask = x64.scheduling.switchTask,
        .prepareTaskForScheduling = x64.scheduling.prepareTaskForScheduling,
        .call = x64.scheduling.call,
        .callNoSave = x64.scheduling.callNoSave,
    },

    .io = .{
        .readPortU8 = struct {
            fn readPortU8(port: decls.io.Port) u8 {
                return x64.instructions.portReadU8(@intFromEnum(port));
            }
        }.readPortU8,
        .readPortU16 = struct {
            fn readPortU16(port: decls.io.Port) u16 {
                return x64.instructions.portReadU16(@intFromEnum(port));
            }
        }.readPortU16,
        .readPortU32 = struct {
            fn readPortU32(port: decls.io.Port) u32 {
                return x64.instructions.portReadU32(@intFromEnum(port));
            }
        }.readPortU32,
        .writePortU8 = struct {
            fn writePortU8(port: decls.io.Port, value: u8) void {
                x64.instructions.portWriteU8(@intFromEnum(port), value);
            }
        }.writePortU8,
        .writePortU16 = struct {
            fn writePortU16(port: decls.io.Port, value: u16) void {
                x64.instructions.portWriteU16(@intFromEnum(port), value);
            }
        }.writePortU16,
        .writePortU32 = struct {
            fn writePortU32(port: decls.io.Port, value: u32) void {
                x64.instructions.portWriteU32(@intFromEnum(port), value);
            }
        }.writePortU32,
    },

    .init = .{
        .getStandardWallclockStartTime = x64.tsc.init.getStandardWallclockStartTime,
        .tryGetSerialOutput = x64.init.tryGetSerialOutput,
        .prepareBootstrapExecutor = x64.init.prepareBootstrapExecutor,
        .prepareExecutor = x64.init.prepareExecutor,
        .loadExecutor = x64.init.loadExecutor,
        .captureEarlySystemInformation = x64.init.captureEarlySystemInformation,
        .captureSystemInformation = x64.init.captureSystemInformation,
        .configureGlobalSystemFeatures = x64.init.configureGlobalSystemFeatures,
        .configurePerExecutorSystemFeatures = x64.init.configurePerExecutorSystemFeatures,
        .registerArchitecturalTimeSources = x64.init.registerArchitecturalTimeSources,
        .initLocalInterruptController = x64.init.initLocalInterruptController,
    },
};

pub const decls: arch.Decls = .{
    .PerExecutor = x64.PerExecutor,

    .interrupts = .{
        .Interrupt = x64.interrupts.Interrupt,
        .InterruptFrame = x64.interrupts.InterruptFrame,
    },

    .paging = .{
        .standard_page_size = .from(4, .kib),
        .largest_page_size = .from(1, .gib),
        .lower_half_size = .from(128, .tib),
        .higher_half_start = .fromInt(0xffff800000000000),
        .PageTable = x64.paging.PageTable,
    },

    .io = .{
        .Port = enum(u16) { _ },
    },

    .init = .{
        .CaptureSystemInformationOptions = x64.init.CaptureSystemInformationOptions,
    },
};
