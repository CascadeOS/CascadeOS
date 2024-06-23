// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: 2024 Lee Cannon <leecannon@leecannon.xyz>

const std = @import("std");
const core = @import("core");
const kernel = @import("kernel");

const log = kernel.log.scoped(.system);

const Cpu = kernel.Cpu;

/// The list of cpus in the system.
///
/// Initialized during `init.initializeCpus`.
var cpus: []Cpu = undefined;

/// Fetch a specific cpus `Cpu` struct.
///
/// `id` must not be `.none`
pub fn getCpu(id: Cpu.Id) *Cpu {
    core.debugAssert(id != .none);

    return &cpus[@intFromEnum(id)];
}

pub const init = struct {
    /// Initialize the per cpu data structures for all cpus including the bootstrap processor.
    ///
    /// Also wakes the non-bootstrap cpus and jumps them to `targetFn`.
    pub fn initializeCpus(comptime targetFn: fn (cpu: *Cpu) noreturn) void {
        var cpu_descriptors = kernel.boot.cpuDescriptors();

        cpus = kernel.heap.eternal_heap_allocator.alloc(
            Cpu,
            cpu_descriptors.count(),
        ) catch core.panic("failed to allocate cpus");

        var i: u32 = 0;

        while (cpu_descriptors.next()) |cpu_descriptor| : (i += 1) {
            const cpu_id: Cpu.Id = @enumFromInt(i);
            const cpu = getCpu(cpu_id);

            log.debug("initializing cpu {}", .{cpu_id});

            const idle_stack = kernel.heap.stack_allocator.create() catch {
                core.panic("failed to allocate idle stack");
            };

            cpu.* = .{
                .id = cpu_id,
                .idle_stack = idle_stack,
                .arch = undefined, // initialized by `prepareCpu`
            };

            kernel.arch.init.prepareCpu(cpu, cpu_descriptor, kernel.heap.stack_allocator.create);

            if (cpu.id != .bootstrap) {
                log.debug("booting processor {}", .{cpu_id});
                cpu_descriptor.boot(cpu, targetFn);
            }
        }
    }
};
