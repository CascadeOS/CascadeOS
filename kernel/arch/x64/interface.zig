// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .getCurrentExecutor = struct {
        inline fn getCurrentExecutor() *kernel.Executor {
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

        .allocateInterrupt = x64.interrupts.allocateInterrupt,
        .deallocateInterrupt = x64.interrupts.deallocateInterrupt,
        .routeInterrupt = x64.interrupts.routeInterrupt,

        .createStackIterator = struct {
            fn createStackIterator(interrupt_frame: *const x64.interrupts.InterruptFrame) std.debug.StackIterator {
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
        .createPageTable = x64.paging.createPageTable,

        .loadPageTable = struct {
            fn loadPageTable(physical_frame: kernel.mem.phys.Frame) void {
                x64.registers.Cr3.writeAddress(physical_frame.baseAddress());
            }
        }.loadPageTable,

        .copyTopLevelIntoPageTable = struct {
            fn copyTopLevelIntoPageTable(
                page_table: *x64.paging.PageTable,
                target_page_table: *x64.paging.PageTable,
            ) void {
                std.debug.assert(page_table != target_page_table);
                @memcpy(&target_page_table.entries, &page_table.entries);
            }
        }.copyTopLevelIntoPageTable,

        .mapSinglePage = x64.paging.map4KiB,
        .unmapSinglePage = x64.paging.unmap4KiB,
        .flushCache = x64.paging.flushCache,

        .init = .{
            .sizeOfTopLevelEntry = struct {
                fn sizeOfTopLevelEntry() core.Size {
                    // TODO: Only correct for 4 level paging
                    return core.Size.from(0x8000000000, .byte);
                }
            }.sizeOfTopLevelEntry,

            .fillTopLevel = x64.paging.init.fillTopLevel,
            .mapToPhysicalRangeAllPageSizes = x64.paging.init.mapToPhysicalRangeAllPageSizes,
        },
    },

    .scheduling = .{
        .prepareForJumpToTaskFromTask = x64.scheduling.prepareForJumpToTaskFromTask,
        .jumpToTask = x64.scheduling.jumpToTask,
        .jumpToTaskFromTask = x64.scheduling.jumpToTaskFromTask,
        .prepareNewTaskForScheduling = x64.scheduling.prepareNewTaskForScheduling,
        .callTwoArgs = x64.scheduling.callTwoArgs,
        .callFourArgs = x64.scheduling.callFourArgs,
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

const arch = @import("arch");
const kernel = @import("kernel");

const x64 = @import("x64.zig");

const core = @import("core");
const std = @import("std");
