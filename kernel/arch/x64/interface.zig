// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

pub const functions: arch.Functions = .{
    .getCurrentExecutor = x64.getCurrentExecutor,
    .spinLoopHint = x64.spinLoopHint,
    .halt = x64.halt,

    .interrupts = .{
        .disableAndHalt = x64.interrupts.disableInterruptsAndHalt,
        .areEnabled = x64.interrupts.areEnabled,
        .enable = x64.interrupts.enableInterrupts,
        .disable = x64.interrupts.disableInterrupts,

        .eoi = x64.interrupts.eoi,
        .sendPanicIPI = x64.interrupts.sendPanicIPI,
        .sendFlushIPI = x64.interrupts.sendFlushIPI,

        .allocateInterrupt = x64.interrupts.allocateInterrupt,
        .deallocateInterrupt = x64.interrupts.deallocateInterrupt,
        .routeInterrupt = x64.interrupts.routeInterrupt,

        .interruptToUsize = struct {
            fn interruptToUsize(interrupt: x64.interrupts.Interrupt) usize {
                return @intFromEnum(interrupt);
            }
        }.interruptToUsize,
        .interruptFromUsize = struct {
            fn interruptFromUsize(interrupt: usize) x64.interrupts.Interrupt {
                return @enumFromInt(interrupt);
            }
        }.interruptFromUsize,

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
        .loadPageTable = x64.paging.loadPageTable,
        .copyTopLevelIntoPageTable = x64.paging.copyTopLevelIntoPageTable,
        .mapSinglePage = x64.paging.mapSinglePage,
        .unmapSinglePage = x64.paging.unmapSinglePage,
        .flushCache = x64.paging.flushCache,

        .init = .{
            .sizeOfTopLevelEntry = x64.paging.init.sizeOfTopLevelEntry,
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
                return lib_x64.instructions.portReadU8(@intFromEnum(port));
            }
        }.readPortU8,
        .readPortU16 = struct {
            fn readPortU16(port: decls.io.Port) u16 {
                return lib_x64.instructions.portReadU16(@intFromEnum(port));
            }
        }.readPortU16,
        .readPortU32 = struct {
            fn readPortU32(port: decls.io.Port) u32 {
                return lib_x64.instructions.portReadU32(@intFromEnum(port));
            }
        }.readPortU32,
        .writePortU8 = struct {
            fn writePortU8(port: decls.io.Port, value: u8) void {
                lib_x64.instructions.portWriteU8(@intFromEnum(port), value);
            }
        }.writePortU8,
        .writePortU16 = struct {
            fn writePortU16(port: decls.io.Port, value: u16) void {
                lib_x64.instructions.portWriteU16(@intFromEnum(port), value);
            }
        }.writePortU16,
        .writePortU32 = struct {
            fn writePortU32(port: decls.io.Port, value: u32) void {
                lib_x64.instructions.portWriteU32(@intFromEnum(port), value);
            }
        }.writePortU32,
    },

    .init = .{
        .getStandardWallclockStartTime = x64.init.getStandardWallclockStartTime,
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
        .standard_page_size = x64.paging.all_page_sizes[0],
        .largest_page_size = x64.paging.all_page_sizes[x64.paging.all_page_sizes.len - 1],
        .lower_half_size = x64.paging.lower_half_size,
        .higher_half_start = x64.paging.higher_half_start,
        .PageTable = lib_x64.PageTable,
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
const lib_x64 = @import("x64");

const core = @import("core");
const std = @import("std");
