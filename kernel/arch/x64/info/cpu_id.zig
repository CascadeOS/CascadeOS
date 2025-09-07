// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Lee Cannon <leecannon@leecannon.xyz>

//! Provides access to CPU information.
//!
//! **Note:** The `capture` function must be called in order to populate the CPUID information.
//!
//! Specification's used:
//!  - "Intel 64 and IA-32 Architectures Software Developer's Manual Volume 2A December 2023"
//!  - "AMD64 Architecture Programmer's Manual Volume 3: General-Purpose and System Instructions 3.36 March 2024"
//!

const std = @import("std");

const bitjuggle = @import("bitjuggle");
const core = @import("core");

const x64 = @import("../x64.zig");

/// Capture the CPUID information.
pub fn capture() !void {
    if (!isAvailable()) return error.CpuIdNotSupported;

    capture00H();
    vendor = determineVendor();
    capture01H();
    capture06H();
    capture07H();
    capture15H();
    capture16H();

    capture80000000H();
    capture80000001H();
    capture80000002H_80000004H();
    capture80000007H();
    capture80000008H();

    if (hypervisor_present) {
        capture40000000H();

        hypervisor = determineHypervisor();

        capture40000010H();
    }
}

/// Returns true if CPUID is available.
///
/// Utilizes the `x64.RFlags.id` field to detect support for CPUID.
pub fn isAvailable() bool {
    const orig_rflags = x64.registers.RFlags.read();
    var modified_rflags = orig_rflags;

    modified_rflags.id = !modified_rflags.id;
    modified_rflags.write();

    const new_rflags = x64.registers.RFlags.read();

    return orig_rflags.id != new_rflags.id;
}

/// The maximum supported standard leaf.
///
/// CPUID.00H: EAX
pub var max_standard_leaf: u32 = 0;

/// The maximum supported sub-leaf for CPUID.07H.
///
/// CPUID.07H: EAX
pub var max_07_subleaf: u32 = 0;

/// The maximum supported extended leaf.
///
/// CPUID.80000000H: EAX
pub var max_extended_leaf: u32 = 0;

/// The maximum supported extended sub-leaf for CPUID.80000001H.
///
/// CPUID.80000001H: ECX
pub var max_hypervisor_leaf: u32 = 0;

/// Vendor identification string.
///
/// CPUID.00H: EBX, ECX, EDX
///
/// See `cpuVendorString`.
pub var _raw_cpu_vendor_string: [12]u8 = [_]u8{0} ** 12;

/// Vendor identification string.
///
/// CPUID.00H: EBX, ECX, EDX
pub fn cpuVendorString() []const u8 {
    return std.mem.sliceTo(&_raw_cpu_vendor_string, 0);
}

pub var vendor: Vendor = .unknown;

pub const Vendor = enum {
    unknown,

    intel,
    amd,
};

/// Processor brand string.
///
/// CPUID.80000002H - CPUID.80000004H
///
/// See `processorBrandString`.
pub var _raw_processor_brand_string: [48]u8 = [_]u8{0} ** 48;

/// Processor brand string.
///
/// CPUID.80000002H - CPUID.80000004H
pub fn processorBrandString() []const u8 {
    return std.mem.sliceTo(&_raw_processor_brand_string, 0);
}

/// Processor stepping ID.
///
/// CPUID.01H: EAX[3:0]
pub var stepping_id: u4 = 0;

/// Processor model ID.
///
/// See `processorModelId`.
///
/// CPUID.01H: EAX[7:4]
pub var _raw_model_id: u4 = 0;

/// Processor family ID.
///
/// See `processorFamilyId`.
///
/// CPUID.01H: EAX[11:8]
pub var _raw_family_id: u4 = 0;

/// Processor type.
///
/// CPUID.01H: EAX[13:12]
pub var processor_type: ProcessorType = .reserved;

/// Processor extended model ID.
///
/// See `processorModelId`.
///
/// CPUID.01H: EAX[19:16]
pub var _raw_extended_model_id: u4 = 0;

/// Processor extended family ID.
///
/// See `processorFamilyId`.
///
/// CPUID.01H: EAX[27:20]
pub var _raw_extended_family_id: u8 = 0;

/// Processor family ID.
///
/// Combines the extended family ID with the family ID if required.
pub fn processorFamilyId() u8 {
    if (_raw_family_id == 0xF) return _raw_family_id + _raw_extended_family_id;
    return _raw_family_id;
}

/// Processor model ID.
///
/// Combines the extended model ID with the model ID if required.
pub fn processorModelId() u8 {
    return switch (vendor) {
        .intel, .unknown => switch (_raw_family_id) {
            0x6, 0xF => (@as(u8, _raw_extended_model_id) << 4) + _raw_model_id,
            else => _raw_model_id,
        },
        .amd => switch (_raw_family_id) {
            0xF => (@as(u8, _raw_extended_model_id) << 4) + _raw_model_id,
            else => _raw_model_id,
        },
    };
}

/// Brand Index / Brand ID.
///
/// #### Intel
/// This number provides an entry into a brand string table that contains brand strings for IA-32 processors.
///
/// #### AMD
/// 8-bit brand ID.
/// This field, in conjunction with CPUID.80000001H: EBX[BrandId], is used by the system firmware to generate the
/// processor name string.
/// See the appropriate processor revision guide for how to program the processor name string.
///
/// CPUID.01H: EBX[7:0]
pub var brand_index: u8 = 0;

/// CLFLUSH line size (Value ∗ 8 = cache line size in bytes; used also by CLFLUSHOPT).
///
/// This number indicates the size of the cache line flushed by the CLFLUSH and CLFLUSHOPT instructions in 8-byte
/// increments.
///
/// This field was introduced in the Pentium 4 processor.
///
/// CPUID.01H: EBX[15:8]
pub var clflush_line_size: u8 = 0;

/// Maximum number of addressable IDs for logical processors in this physical package.
///
/// The nearest power-of-2 integer that is not smaller than this is the number of unique initial APIC IDs
/// reserved for addressing different logical processors in a physical package.
///
/// This field is only valid if `htt` (CPUID.01H: EDX[28]) is `true`.
///
/// CPUID.01H: EBX[23:16]
pub var maximum_number_of_addressable_ids: u8 = 0;

/// Initial APIC ID.
///
/// This number is the 8-bit ID that is assigned to the local APIC on the processor during power up.
///
/// This field was introduced in the Pentium 4 processor.
///
/// The 8-bit initial APIC ID is replaced by the 32-bit x2APIC ID, available in 0BH and 1FH.
///
/// CPUID.01H: EBX[31:24]
pub fn initialApicId() ?u8 {
    if (max_standard_leaf < 0x01) return null;

    const cpuid_result = raw(0x01, 0);

    const Info = packed struct(u32) {
        brand_index: u8,
        clflush_line_size: u8,
        maximum_number_of_addressable_ids: u8,
        initial_apic_id: u8,
    };
    const info: Info = @bitCast(cpuid_result.ebx);

    return info.initial_apic_id;
}

/// Streaming SIMD Extensions 3 (SSE3).
///
/// CPUID.01H: ECX[0]
pub var sse3: bool = false;

/// PCLMULQDQ instruction.
///
/// CPUID.01H: ECX[1]
pub var pclmulqdq: bool = false;

/// 64-bit DS Area.
///
/// Indicates the processor supports DS area using 64-bit layout.
///
/// Intel only.
///
/// CPUID.01H: ECX[2]
pub var intel_dtes64: bool = false;

/// MONITOR/MWAIT.
///
/// Indicates the processor supports this feature.
///
/// CPUID.01H: ECX[3]
pub var monitor: bool = false;

/// CPL Qualified Debug Store.
///
/// Indicates the processor supports the extensions to the Debug Store feature to allow for branch message storage qualified by CPL.
///
/// Intel only.
///
/// CPUID.01H: ECX[4]
pub var intel_ds_cpl: bool = false;

/// Virtual Machine Extensions.
///
/// Indicates that the processor supports this technology.
///
/// Intel only.
///
/// CPUID.01H: ECX[5]
pub var intel_vmx: bool = false;

/// Safer Mode Extensions.
///
/// Indicates that the processor supports this technology.
///
/// Intel only.
///
/// CPUID.01H: ECX[6]
pub var intel_smx: bool = false;

/// Enhanced Intel SpeedStep technology.
///
/// Indicates that the processor supports this technology.
///
/// Intel only.
///
/// CPUID.01H: ECX[7]
pub var intel_eist: bool = false;

/// Thermal Monitor 2.
///
/// Indicates whether the processor supports this technology.
///
/// Intel only.
///
/// CPUID.01H: ECX[8]
pub var intel_tm2: bool = false;

/// Supplemental Streaming SIMD Extensions 3 (SSSE3).
///
/// Indicates whether the processor supports this technology.
///
/// CPUID.01H: ECX[9]
pub var ssse3: bool = false;

/// L1 Context ID.
///
/// Indicates the L1 data cache mode can be set to either adaptive mode or shared mode.
///
/// See definition of the IA32_MISC_ENABLE MSR Bit 24 (L1 Data Cache Context Mode) for details.
///
/// Intel only.
///
/// CPUID.01H: ECX[10]
pub var intel_cnxt_id: bool = false;

/// Indicates the processor supports IA32_DEBUG_INTERFACE MSR for silicon debug.
///
/// Intel only.
///
/// CPUID.01H: ECX[11]
pub var intel_sdbg: bool = false;

/// Indicates the processor supports FMA extensions using YMM state.
///
/// CPUID.01H: ECX[12]
pub var fma: bool = false;

/// CMPXCHG16B.
///
/// Indicates that the feature is available.
///
/// CPUID.01H: ECX[13]
pub var cmpxchg16b: bool = false;

/// xTPR Update Control.
///
/// Indicates that the processor supports changing IA32_MISC_ENABLE[bit 23].
///
/// Intel only.
///
/// CPUID.01H: ECX[14]
pub var intel_xtpr_update_control: bool = false;

/// Perfmon and Debug Capability.
///
/// Indicates the processor supports the performance and debug feature indication MSR IA32_PERF_CAPABILITIES.
///
/// Intel only.
///
/// CPUID.01H: ECX[15]
pub var intel_pdcm: bool = false;

/// Process-context identifiers.
///
/// Indicates that the processor supports PCIDs and that software may set CR4.PCIDE to 1.
///
/// Intel only.
///
/// CPUID.01H: ECX[17]
pub var intel_pcid: bool = false;

/// Indicates the processor supports the ability to prefetch data from a memory mapped device.
///
/// Intel only.
///
/// CPUID.01H: ECX[18]
pub var intel_dca: bool = false;

/// Indicates that the processor supports SSE4.1.
///
/// CPUID.01H: ECX[19]
pub var sse4_1: bool = false;

/// Indicates that the processor supports SSE4.2.
///
/// CPUID.01H: ECX[20]
pub var sse4_2: bool = false;

/// Indicates that the processor supports x2APIC feature.
///
/// CPUID.01H: ECX[21]
pub var x2apic: bool = false;

/// Indicates that the processor supports MOVBE instruction.
///
/// CPUID.01H: ECX[22]
pub var movbe: bool = false;

/// Indicates that the processor supports POPCNT instruction.
///
/// CPUID.01H: ECX[23]
pub var popcnt: bool = false;

/// Indicates that the processor’s local APIC timer supports one-shot operation using a TSC deadline value.
///
/// Intel only.
///
/// CPUID.01H: ECX[24]
pub var intel_tsc_deadline: bool = false;

/// Indicates that the processor supports the AESNI instruction extensions.
///
/// CPUID.01H: ECX[25]
pub var aesni: bool = false;

/// Indicates that the processor supports the XSAVE/XRSTOR processor extended states feature; the XSETBV/XGETBV
/// instructions; and XCR0.
///
/// CPUID.01H: ECX[26]
pub var xsave: bool = false;

/// Indicates that the OS has set CR4.OSXSAVE[bit 18] to enable XSETBV/XGETBV instructions to access XCR0 and to support
/// processor extended state management using XSAVE/XRSTOR.
///
/// CPUID.01H: ECX[27]
pub var osxsave: bool = false;

/// Indicates the processor supports the AVX instruction extensions.
///
/// CPUID.01H: ECX[28]
pub var avx: bool = false;

/// Indicates that the processor supports 16-bit floating-point conversion instructions.
///
/// CPUID.01H: ECX[29]
pub var f16c: bool = false;

/// Indicates that the processor supports RDRAND instruction.
///
/// CPUID.01H: ECX[30]
pub var rdrand: bool = false;

/// Hypervisor present.
///
/// CPUID.01H: ECX[31]
pub var hypervisor_present: bool = false;

/// Floating-Point Unit On-Chip.
///
/// The processor contains an x87 FPU.
///
/// CPUID.01H: EDX[0]
pub var fpu: bool = false;

/// Virtual 8086 Mode Enhancements.
///
/// Virtual 8086 mode enhancements, including CR4.VME for controlling the feature, CR4.PVI for protected mode virtual
/// interrupts, software interrupt indirection, expansion of the TSS with the software indirection bitmap, and
/// EFLAGS.VIF and EFLAGS.VIP flags.
///
/// CPUID.01H: EDX[1]
pub var vme: bool = false;

/// Debugging Extensions.
///
/// Support for I/O breakpoints, including CR4.DE for controlling the feature, and optional trapping of accesses
/// to DR4 and DR5.
///
/// CPUID.01H: EDX[2]
pub var de: bool = false;

/// Page Size Extension.
///
/// Large pages of size 4 MByte are supported, including CR4.PSE for controlling the feature, the defined dirty bit
/// in PDE (Page Directory Entries), optional reserved bit trapping in CR3, PDEs, and PTEs.
///
/// CPUID.01H: EDX[3]
pub var pse: bool = false;

/// Time Stamp Counter.
///
/// The RDTSC instruction is supported, including CR4.TSD for controlling privilege.
///
/// CPUID.01H: EDX[4]
pub var tsc: bool = false;

/// Model Specific Registers RDMSR and WRMSR Instructions.
///
/// The RDMSR and WRMSR instructions are supported. Some of the MSRs are implementation dependent.
///
/// CPUID.01H: EDX[5]
pub var msr: bool = false;

/// Physical Address Extension.
///
/// Physical addresses greater than 32 bits are supported: extended page table entry formats, an extra level in the
/// page translation tables is defined, 2-MByte pages are supported instead of 4 Mbyte pages if PAE bit is 1.
///
/// CPUID.01H: EDX[6]
pub var pae: bool = false;

/// Machine Check Exception.
///
/// Exception 18 is defined for Machine Checks, including CR4.MCE for controlling the feature.
///
/// This feature does not define the model-specific implementations of machine-check error logging, reporting, and
/// processor shutdowns.
///
/// Machine Check exception handlers may have to depend on processor version to do model specific processing of the
/// exception, or test for the presence of the Machine Check feature.
///
/// CPUID.01H: EDX[7]
pub var mce: bool = false;

/// CMPXCHG8B Instruction.
///
/// The compare-and-exchange 8 bytes (64 bits) instruction is supported (implicitly locked and atomic).
///
/// CPUID.01H: EDX[8]
pub var cx8: bool = false;

/// APIC On-Chip.
///
/// The processor contains an Advanced Programmable Interrupt Controller (APIC), responding to memory mapped commands
/// in the physical address range FFFE0000H to FFFE0FFFH (by default - some processors permit the APIC to be relocated).
///
/// CPUID.01H: EDX[9]
pub var apic: bool = false;

/// SYSENTER and SYSEXIT Instructions.
///
/// The SYSENTER and SYSEXIT and associated MSRs are supported.
///
/// CPUID.01H: EDX[11]
pub var sep: bool = false;

/// Memory Type Range Registers. MTRRs are supported.
///
/// The MTRRcap MSR contains feature bits that describe what memory types are supported, how many variable MTRRs are
/// supported, and whether fixed MTRRs are supported.
///
/// CPUID.01H: EDX[12]
pub var mtrr: bool = false;

/// Page Global Bit.
///
/// The global bit is supported in paging-structure entries that map a page, indicating TLB entries that are common to
/// different processes and need not be flushed.
///
/// The CR4.PGE bit controls this feature.
///
/// CPUID.01H: EDX[13]
pub var pge: bool = false;

/// Machine Check Architecture.
///
/// A value of `true` indicates the Machine Check Architecture of reporting machine errors is supported.
///
/// The MCG_CAP MSR contains feature bits describing how many banks of error reporting MSRs are supported.
///
/// CPUID.01H: EDX[14]
pub var mca: bool = false;

/// Conditional Move Instructions. The conditional move instruction CMOV is supported.
///
/// In addition, if x87 FPU is present as indicated by the CPUID.FPU feature bit, then the FCOMI and FCMOV instructions
/// are supported
///
/// CPUID.01H: EDX[15]
pub var cmov: bool = false;

/// Page Attribute Table. Page Attribute Table is supported.
///
/// This feature augments the Memory Type Range Registers (MTRRs), allowing an operating system to specify attributes
/// of memory accessed through a linear address on a 4KB granularity.
///
/// CPUID.01H: EDX[16]
pub var pat: bool = false;

/// 36-Bit Page Size Extension.
///
/// 4-MByte pages addressing physical memory beyond 4 GBytes are supported with 32-bit paging.
///
/// This feature indicates that upper bits of the physical address of a 4-MByte page are encoded in bits 20:13 of the
/// page-directory entry. Such physical addresses are limited by MAXPHYADDR and may be up to 40 bits in size.
///
/// CPUID.01H: EDX[17]
pub var pse_36: bool = false;

/// Processor Serial Number.
///
/// The processor supports the 96-bit processor identification number feature and the feature is enabled.
///
/// Intel Only.
///
/// CPUID.01H: EDX[18]
pub var intel_psn: bool = false;

/// CLFLUSH Instruction.
///
/// CLFLUSH Instruction is supported.
///
/// CPUID.01H: EDX[19]
pub var clfsh: bool = false;

/// Debug Store.
///
/// The processor supports the ability to write debug information into a memory resident buffer.
///
/// This feature is used by the branch trace store (BTS) and processor event-based sampling (PEBS) facilities.
///
/// Intel Only.
///
/// CPUID.01H: EDX[21]
pub var intel_ds: bool = false;

/// Thermal Monitor and Software Controlled Clock Facilities.
///
/// The processor implements internal MSRs that allow processor temperature to be monitored and processor performance
/// to be modulated in predefined duty cycles under software control.
///
/// Intel Only.
///
/// CPUID.01H: EDX[22]
pub var intel_acpi: bool = false;

/// Intel MMX Technology.
///
/// The processor supports the Intel MMX technology.
///
/// CPUID.01H: EDX[23]
pub var mmx: bool = false;

/// FXSAVE and FXRSTOR Instructions.
///
/// The FXSAVE and FXRSTOR instructions are supported for fast save and restore of the floating-point context.
///
/// Presence of this bit also indicates that CR4.OSFXSR is available for an operating system to indicate that it
/// supports the FXSAVE and FXRSTOR instructions.
///
/// CPUID.01H: EDX[24]
pub var fxsr: bool = false;

/// SSE.
///
/// The processor supports the SSE extensions.
///
/// CPUID.01H: EDX[25]
pub var sse: bool = false;

/// SSE2.
///
/// The processor supports the SSE2 extensions.
///
/// CPUID.01H: EDX[26]
pub var sse2: bool = false;

/// Self Snoop.
///
/// The processor supports the management of conflicting memory types by performing a snoop of its own cache structure
/// for transactions issued to the bus.
///
/// Intel Only.
///
/// CPUID.01H: EDX[27]
pub var intel_ss: bool = false;

/// Max APIC IDs reserved field is Valid.
///
/// A value of `false` indicates there is only a single logical processor in the package and software should assume
/// only a single APIC ID is reserved.
///
/// A value of `true` indicates the value in `maximum_number_of_addressable_ids` is valid for the package.
///
/// CPUID.01H: EDX[28]
pub var htt: bool = false;

/// Thermal Monitor.
///
/// The processor implements the thermal monitor automatic thermal control circuitry (TCC).
///
/// Intel Only.
///
/// CPUID.01H: EDX[29]
pub var intel_tm: bool = false;

/// Pending Break Enable.
///
/// The processor supports the use of the FERR#/PBE# pin when the processor is in the stop-clock state (STPCLK# is
/// asserted) to signal the processor that an interrupt is pending and that the processor should return to normal
/// operation to handle the interrupt.
///
/// Intel Only.
///
/// CPUID.01H: EDX[31]
pub var intel_pbe: bool = false;

/// Digital temperature sensor.
///
/// Intel Only.
///
/// CPUID.06H: EAX[0]
pub var intel_digital_temperature_sensor: bool = false;

/// Intel Turbo Boost Technology available (see description of IA32_MISC_ENABLE[38]).
///
/// Intel Only.
///
/// CPUID.06H: EAX[1]
pub var intel_turbo_boost: bool = false;

/// ARAT.
///
/// APIC-Timer-always-running feature.
///
/// CPUID.06H: EAX[2]
pub var arat: bool = false;

/// PLN.
///
/// Intel Only.
///
/// Power limit notification controls.
///
/// CPUID.06H: EAX[4]
pub var intel_pln: bool = false;

/// ECMD.
///
/// Intel Only.
///
/// Clock modulation duty cycle extension.
///
/// CPUID.06H: EAX[5]
pub var intel_ecmd: bool = false;

/// PTM.
///
/// Intel Only.
///
/// Package thermal management.
///
/// CPUID.06H: EAX[6]
pub var intel_ptm: bool = false;

/// HWP.
///
/// HWP base registers are supported:
///  - IA32_PM_ENABLE[bit 0]
///  - IA32_HWP_CAPABILITIES
///  - IA32_HWP_REQUEST
///  - IA32_HWP_STATUS
///
/// Intel Only.
///
/// CPUID.06H: EAX[7]
pub var intel_hwp: bool = false;

/// HWP_Notification.
///
/// IA32_HWP_INTERRUPT MSR.
///
/// Intel Only.
///
/// CPUID.06H: EAX[8]
pub var intel_hwp_notification: bool = false;

/// HWP_Activity_Window.
///
/// IA32_HWP_REQUEST[bits 41:32].
///
/// Intel Only.
///
/// CPUID.06H: EAX[9]
pub var intel_hwp_activity_window: bool = false;

/// HWP_Energy_Performance_Preference.
///
/// IA32_HWP_REQUEST[bits 31:24]
///
/// Intel Only.
///
/// CPUID.06H: EAX[10]
pub var intel_hwp_energy_performance_preference: bool = false;

/// HWP_Package_Level_Request.
///
/// IA32_HWP_REQUEST_PKG MSR.
///
/// Intel Only.
///
/// CPUID.06H: EAX[11]
pub var intel_hwp_package_level_request: bool = false;

/// HDC.
///
/// HDC base registers are available:
///  - IA32_PKG_HDC_CTL
///  - IA32_PM_CTL1
///  - IA32_THREAD_STALL
///
/// Intel Only.
///
/// CPUID.06H: EAX[13]
pub var intel_hdc: bool = false;

/// Intel Turbo Boost Max Technology 3.0
///
/// Intel Only.
///
/// CPUID.06H: EAX[14]
pub var intel_turbo_boost_3: bool = false;

/// HWP Capabilities. Highest Performance change.
///
/// Intel Only.
///
/// CPUID.06H: EAX[15]
pub var intel_highest_performance_change: bool = false;

/// HWP PECI override.
///
/// Intel Only.
///
/// CPUID.06H: EAX[16]
pub var intel_hwp_peci_override: bool = false;

/// Flexible HWP.
///
/// Intel Only.
///
/// CPUID.06H: EAX[17]
pub var intel_flexible_hwp: bool = false;

/// Fast access mode for the IA32_HWP_REQUEST MSR.
///
/// Intel Only.
///
/// CPUID.06H: EAX[18]
pub var intel_fast_ia32_hwp_request: bool = false;

/// HW_FEEDBACK.
///
/// Supported:
///  - IA32_HW_FEEDBACK_PTR MSR
///  - IA32_HW_FEEDBACK_CONFIG MSR
///  - IA32_PACKAGE_THERM_STATUS MSR bit 26
///  - IA32_PACKAGE_THERM_INTERRUPT MSR bit 25
///
/// Intel Only.
///
/// CPUID.06H: EAX[19]
pub var intel_hw_feedback: bool = false;

/// Ignoring Idle Logical Processor HWP request is supported.
///
/// Intel Only.
///
/// CPUID.06H: EAX[20]
pub var intel_ignore_hwp_request: bool = false;

/// Intel Thread Director supported if set.
///
/// IA32_HW_FEEDBACK_CHAR and IA32_HW_FEEDBACK_THREAD_CONFIG MSRs are supported if set.
///
/// Intel Only.
///
/// CPUID.06H: EAX[23]
pub var intel_thread_director: bool = false;

/// IA32_THERM_INTERRUPT MSR bit 25 is supported.
///
/// Intel Only.
///
/// CPUID.06H: EAX[24]
pub var intel_ia32_therm_interrupt: bool = false;

/// Number of Interrupt Thresholds in Digital Thermal Sensor.
///
/// Intel Only.
///
/// CPUID.06H: EBX[3:0]
pub var intel_digital_thermal_sensor_interrupt_thresholds: ?u4 = null;

/// Presence of IA32_MPERF and IA32_APERF.
///
/// #### Intel
/// The capability to provide a measure of delivered processor performance (since last reset of the counters), as a
/// percentage of the expected processor performance when running at the TSC frequency.
///
/// #### AMD
/// Effective frequency interface support.
/// If set, indicates presence of MSR0000_00E7 (MPERF) and MSR0000_00E8 (APERF).
///
/// CPUID.06H: ECX[0]
pub var ia32_mperf_ia32_aperf: bool = false;

/// The processor supports performance-energy bias preference if CPUID.06H:ECX.SETBH[bit 3] is set and it also implies
/// the presence of a new architectural MSR called IA32_ENERGY_PERF_BIAS (1B0H).
///
/// Intel Only.
///
/// CPUID.06H: ECX[3]
pub var intel_ia32_energy_perf_bias: bool = false;

/// Number of Intel Thread Director classes supported by the processor.
///
/// Information for that many classes is written into the Intel Thread Director Table by the hardware.
///
/// Intel Only.
///
/// CPUID.06H: ECX[15:8]
pub var intel_thread_director_classes_supported: ?u8 = null;

/// Performance capability reporting.
///
/// Intel Only.
///
/// CPUID.06H: EDX[0]
pub var intel_performance_capability_reporting: bool = false;

/// Energy efficiency capability reporting.
///
/// Intel Only.
///
/// CPUID.06H: EDX[1]
pub var intel_energy_efficiency_capability_reporting: bool = false;

/// Enumerates the size of the hardware feedback interface structure in number of 4 KB pages.
///
/// Intel Only.
///
/// CPUID.06H: EDX[11:8]
pub var intel_hardware_feedback_interface_size: ?u5 = null;

/// Index (starting at 0) of this logical processor's row in the hardware feedback interface structure.
///
/// Note that on some parts the index may be same for multiple logical processors.
///
/// On some parts the indices may not be contiguous, i.e., there may be unused rows in the hardware feedback interface
/// structure.
///
/// Intel Only.
///
/// CPUID.06H: EDX[31:16]
pub fn intelIndexInHardwareFeedbackInterface() ?u16 {
    if (max_standard_leaf < 0x06) return null;

    const cpuid_result = raw(0x06, 0);

    return bitjuggle.getBits(cpuid_result.edx, 16, 16);
}

/// Supports RDFSBASE/RDGSBASE/WRFSBASE/WRGSBASE.
///
/// CPUID.07.00H: EBX[0]
pub var fsgsbase: bool = false;

/// IA32_TSC_ADJUST MSR is supported
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[1]
pub var intel_ia32_tsc_adjust: bool = false;

/// SGX.
///
/// Supports Intel Software Guard Extensions (Intel SGX Extensions)
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[2]
pub var intel_sgx: bool = false;

/// BMI1.
///
/// CPUID.07.00H: EBX[3]
pub var bmi1: bool = false;

/// HLE.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[4]
pub var intel_hle: bool = false;

/// AVX2.
///
/// Supports Intel Advanced Vector Extensions 2 (Intel® AVX2)
///
/// CPUID.07.00H: EBX[5]
pub var avx2: bool = false;

/// FDP_EXCPTN_ONLY.
///
/// x87 FPU Data Pointer updated only on x87 exceptions.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[6]
pub var intel_fdp_excptn_only: bool = false;

/// SMEP.
///
/// Supports Supervisor-Mode Execution Prevention.
///
/// CPUID.07.00H: EBX[7]
pub var smep: bool = false;

/// BMI2.
///
/// CPUID.07.00H: EBX[8]
pub var bmi2: bool = false;

/// Supports Enhanced REP MOVSB/STOSB.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[9]
pub var intel_enhanced_repmovsb: bool = false;

/// INVPCID.
///
/// Supports INVPCID instruction for system software that manages process-context identifiers.
///
/// CPUID.07.00H: EBX[10]
pub var invpcid: bool = false;

/// RTM.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[11]
pub var intel_rtm: bool = false;

/// RDT-M.
///
/// Supports Intel Resource Director Technology (Intel RDT) Monitoring capability.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[12]
pub var intel_rdt_m: bool = false;

/// PQM.
///
/// Platform QOS Monitoring support.
///
/// AMD Only.
///
/// CPUID.07.00H: EBX[12]
pub var amd_pqm: bool = false;

/// Deprecates FPU CS and FPU DS values.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[13]
pub var intel_deprecate_fpu_cs_ds: bool = false;

/// MPX.
///
/// Supports Intel Memory Protection Extensions.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[14]
pub var intel_mpx: bool = false;

/// RDT-A.
///
/// Supports Intel Resource Director Technology (Intel RDT) Allocation capability.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[15]
pub var intel_rdt_a: bool = false;

/// PQE.
///
/// Platform QOS Enforcement support.
///
/// AMD Only.
///
/// CPUID.07.00H: EBX[15]
pub var amd_pqe: bool = false;

/// AVX512F.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[16]
pub var intel_avx512f: bool = false;

/// AVX512DQ.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[17]
pub var intel_avx512dq: bool = false;

/// RDSEED.
///
/// CPUID.07.00H: EBX[18]
pub var rdseed: bool = false;

/// ADX.
///
/// CPUID.07.00H: EBX[19]
pub var adx: bool = false;

/// SMAP.
///
/// Supports Supervisor-Mode Access Prevention (and the CLAC/STAC instructions).
///
/// CPUID.07.00H: EBX[20]
pub var smap: bool = false;

/// AVX512_IFMA.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[21]
pub var intel_avx512_ifma: bool = false;

/// RDPID and IA32_TSC_AUX are available.
///
/// CPUID.07.00H: ECX[22]
pub var rdpid: bool = false;

/// CLFLUSHOPT.
///
/// CPUID.07.00H: EBX[23]
pub var clflushopt: bool = false;

/// CLWB.
///
/// CPUID.07.00H: EBX[24]
pub var clwb: bool = false;

/// Intel Processor Trace.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[25]
pub var intel_processor_trace: bool = false;

/// AVX512PF.
///
/// Intel Xeon Phi only.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[26]
pub var intel_avx512pf: bool = false;

/// AVX512ER.
///
/// Intel Xeon Phi only.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[27]
pub var intel_avx512er: bool = false;

/// AVX512CD.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[28]
pub var intel_avx512cd: bool = false;

/// SHA.
///
/// Supports Intel Secure Hash Algorithm Extensions.
///
/// CPUID.07.00H: EBX[29]
pub var sha: bool = false;

/// AVX512BW.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[30]
pub var intel_avx512bw: bool = false;

/// AVX512VL.
///
/// Intel Only.
///
/// CPUID.07.00H: EBX[31]
pub var intel_avx512vl: bool = false;

/// PREFETCHWT1.
///
/// Intel Xeon Phi only.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[0]
pub var intel_prefetchwt1: bool = false;

/// AVX512_VBMI.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[1]
pub var intel_avx512_vbmi: bool = false;

/// UMIP.
///
/// Supports user-mode instruction prevention.
///
/// CPUID.07.00H: ECX[2]
pub var umip: bool = false;

/// PKU.
///
/// Supports protection keys for user-mode pages.
///
/// CPUID.07.00H: ECX[3]
pub var pku: bool = false;

/// OSPKE.
///
/// If `true` the OS has set CR4.PKE to enable protection keys (and the RDPKRU/WRPKRU instructions).
///
/// CPUID.07.00H: ECX[4]
pub fn ospke() bool {
    if (max_standard_leaf < 0x7) return false;
    const leaf0 = raw(0x7, 0);
    return bitjuggle.isBitSet(leaf0.ecx, 4);
}

/// WAITPKG.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[5]
pub var intel_waitpkg: bool = false;

/// AVX512_VBMI2.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[6]
pub var intel_avx512_vbmi2: bool = false;

/// CET_SS. Supports CET shadow stack features.
///
/// Processors that set this bit define bits 1:0 of the IA32_U_CET and IA32_S_CET MSRs.
///
/// Enumerates support for the following MSRs:
///  - IA32_INTERRUPT_SPP_TABLE_ADDR
///  - IA32_PL3_SSP
///  - IA32_PL2_SSP
///  - IA32_PL1_SSP
///  - IA32_PL0_SSP.
///
/// CPUID.07.00H: ECX[7]
pub var cet_ss: bool = false;

/// GFNI.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[8]
pub var intel_gfni: bool = false;

/// VAES.
///
/// CPUID.07.00H: ECX[9]
pub var vaes: bool = false;

/// VPCLMULQDQ.
///
/// CPUID.07.00H: ECX[10]
pub var vpclmulqdq: bool = false;

/// AVX512_VNNI.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[11]
pub var intel_avx512_vnni: bool = false;

/// AVX512_BITALG.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[12]
pub var intel_avx512_bitalg: bool = false;

/// TME_EN.
///
/// The following MSRs are supported:
///  - IA32_TME_CAPABILITY
///  - IA32_TME_ACTIVATE
///  - IA32_TME_EXCLUDE_MASK
///  - IA32_TME_EXCLUDE_BASE
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[13]
pub var intel_tme_en: bool = false;

/// AVX512_VPOPCNTDQ.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[14]
pub var intel_avx512_vpopcntdq: bool = false;

/// LA57.
///
/// Supports 57-bit linear addresses and five-level paging.
///
/// CPUID.07.00H: ECX[16]
pub var la57: bool = false;

/// The value of MAWAU used by the BNDLDX and BNDSTX instructions in 64-bit mode.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[21:17]
pub var intel_mawau: ?u5 = null;

/// KL. Supports Key Locker.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[23]
pub var intel_kl: bool = false;

/// BUS_LOCK_DETECT.
///
/// If `true`, indicates support for OS bus-lock detection.
///
/// CPUID.07.00H: ECX[24]
pub fn busLockDetect() bool {
    if (max_standard_leaf < 0x7) return false;
    const leaf0 = raw(0x7, 0);
    return bitjuggle.isBitSet(leaf0.ecx, 25);
}

/// CLDEMOTE. Supports cache line demote.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[25]
pub var intel_cldemote: bool = false;

/// MOVDIRI.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[27]
pub var intel_movdiri: bool = false;

/// MOVDIR64B.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[28]
pub var intel_movdir64b: bool = false;

/// ENQCMD.
///
/// Supports Enqueue Stores.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[29]
pub var intel_enqcmd: bool = false;

/// SGX_LC.
///
/// Supports SGX Launch Configuration.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[30]
pub var intel_sgx_lc: bool = false;

/// PKS.
///
/// Supports protection keys for supervisor-mode pages.
///
/// Intel Only.
///
/// CPUID.07.00H: ECX[31]
pub var intel_pks: bool = false;

/// SGX-KEYS.
///
/// Attestation Services for Intel SGX is supported.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[1]
pub var intel_sgx_keys: bool = false;

/// AVX512_4VNNIW.
///
/// Intel Xeon Phi only.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[2]
pub var intel_avx512_4vnniw: bool = false;

/// AVX512_4FMAPS.
///
/// Intel Xeon Phi only.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[3]
pub var intel_avx512_4fmaps: bool = false;

/// Fast Short REP MOV.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[4]
pub var intel_fast_short_rep_mov: bool = false;

/// UINTR.
///
/// The processor supports user interrupts.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[5]
pub var intel_uintr: bool = false;

/// AVX512_VP2INTERSECT.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[8]
pub var intel_avx512_vp2intersect: bool = false;

/// SRBDS_CTRL.
///
/// Enumerates support for the IA32_MCU_OPT_CTRL MSR and indicates its bit 0 (RNGDS_MITG_DIS) is also supported.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[9]
pub var intel_srbds_ctrl: bool = false;

/// MD_CLEAR.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[10]
pub var intel_md_clear: bool = false;

/// RTM_ALWAYS_ABORT.
///
/// Any execution of XBEGIN immediately aborts and transitions to the specified fallback address.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[11]
pub var intel_rtm_always_abort: bool = false;

/// RTM_FORCE_ABORT supported.
///
/// Processors that set this bit support the IA32_TSX_FORCE_ABORT MSR.
/// They allow software to set IA32_TSX_FORCE_ABORT[0] (RTM_FORCE_ABORT).
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[13]
pub var intel_rtm_force_abort: bool = false;

/// SERIALIZE.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[14]
pub var intel_serialize: bool = false;

/// Hybrid.
///
/// The processor is identified as a hybrid part.
///
/// If CPUID.0.MAXLEAF ≥ 1AH and CPUID.1A.EAX ≠ 0, then the Native Model ID Enumeration 1AH exists.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[15]
pub var intel_hybrid: bool = false;

/// TSXLDTRK.
///
/// The processor supports Intel TSX suspend/resume of load address tracking.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[16]
pub var intel_tsxldtrk: bool = false;

/// PCONFIG.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[18]
pub var intel_pconfig: bool = false;

/// Architectural LBRs.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[19]
pub var intel_architectural_lbrs: bool = false;

/// CET_IBT.
///
/// Supports CET indirect branch tracking features.
///
/// Processors that set this bit define bits 5:2 and bits 63:10 of the IA32_U_CET and IA32_S_CET MSRs.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[20]
pub var intel_cet_ibt: bool = false;

/// AMX-BF16.
///
/// The processor supports tile computational operations on bfloat16 numbers.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[22]
pub var intel_amx_bf16: bool = false;

/// AVX512_FP16.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[23]
pub var intel_avx512_fp16: bool = false;

/// AMX-TILE.
///
/// The processor supports tile architecture.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[24]
pub var intel_amx_tile: bool = false;

/// AMX-INT8.
///
/// The processor supports tile computational operations on 8-bit integers.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[25]
pub var intel_amx_int8: bool = false;

/// Enumerates support for indirect branch restricted speculation (IBRS) and the indirect branch predictor barrier
/// (IBPB).
///
/// Processors that set this bit support the IA32_SPEC_CTRL MSR and the IA32_PRED_CMD MSR.
///
/// They allow software to set IA32_SPEC_CTRL[0] (IBRS) and IA32_PRED_CMD[0] (IBPB).
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[26]
pub var intel_ibrs_ibpb: bool = false;

/// Enumerates support for single thread indirect branch predictors (STIBP).
///
/// Processors that set this bit support the IA32_SPEC_CTRL MSR. They allow software to set IA32_SPEC_CTRL[1] (STIBP).
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[27]
pub var intel_stibp: bool = false;

/// Enumerates support for L1D_FLUSH.
///
/// Processors that set this bit support the IA32_FLUSH_CMD MSR.
///
/// They allow software to set IA32_FLUSH_CMD[0] (L1D_FLUSH).
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[28]
pub var intel_l1d_flush: bool = false;

/// IA32_ARCH_CAPABILITIES MSR.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[29]
pub var intel_ia32_arch_capabilities: bool = false;

/// IA32_CORE_CAPABILITIES MSR.
///
/// IA32_CORE_CAPABILITIES is an architectural MSR that enumerates model-specific features.
///
/// A bit being set in this MSR indicates that a model specific feature is supported; software must still consult CPUID
/// family/model/stepping to determine the behavior of the enumerated feature as features enumerated in
/// IA32_CORE_CAPABILITIES may have different behavior on different processor models.
///
/// Some of these features may have behavior that is consistent across processor models (and for which consultation of
/// CPUID family/model/stepping is not necessary); such features are identified explicitly where they are documented in
/// this manual.
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[30]
pub var intel_ia32_core_capabilities: bool = false;

/// Enumerates support for Speculative Store Bypass Disable (SSBD).
///
/// Processors that set this bit support the IA32_SPEC_CTRL MSR.
///
/// They allow software to set IA32_SPEC_CTRL[2] (SSBD).
///
/// Intel Only.
///
/// CPUID.07.00H: EDX[31]
pub var intel_ssbd: bool = false;

/// AVX-VNNI.
///
/// AVX (VEX-encoded) versions of the Vector Neural Network Instructions.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[4]
pub var intel_avx_vnni: bool = false;

/// AVX512_BF16.
///
/// Vector Neural Network Instructions supporting BFLOAT16 inputs and conversion instructions from IEEE single precision.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[5]
pub var intel_avx512_bf16: bool = false;

/// Fast zero-length REP MOVSB.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[10]
pub var intel_fast_zero_length_repmovsb: bool = false;

/// Fast short REP STOSB.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[11]
pub var intel_fast_short_repstosb: bool = false;

/// Fast short REP CMPSB, REP SCASB.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[12]
pub var intel_fast_short_repcmpsb: bool = false;

/// HRESET.
///
/// Supports history reset via the HRESET instruction and the IA32_HRESET_ENABLE MSR.
///
/// When set, indicates that the Processor History Reset (EAX = 20H) is valid.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[22]
pub var intel_hreset: bool = false;

/// INVD_DISABLE_POST_BIOS_DONE.
///
/// Supports INVD execution prevention after BIOS Done.
///
/// Intel Only.
///
/// CPUID.07.01H: EAX[30]
pub var intel_invd_disable_post_bios_done: bool = false;

/// Enumerates the presence of the IA32_PPIN and IA32_PPIN_CTL MSRs.
///
/// Intel Only.
///
/// CPUID.07.01H: EBX[0]
pub var intel_ia32_ppin: bool = false;

/// CET_SSS.
///
/// Indicates that an operating system can enable supervisor shadow stacks as long as it ensures that a supervisor
/// shadow stack cannot become prematurely busy due to page faults.
///
/// When emulating the CPUID instruction, a virtual-machine monitor (VMM) should return this bit as 1 only if it ensures
/// that VM exits cannot cause a guest supervisor shadow stack to appear to be prematurely busy.
/// Such a VMM could set the "prematurely busy shadow stack" VM-exit control and use the additional information that it
/// provides.
///
/// Intel Only.
///
/// CPUID.07.01H: EDX[18]
pub var intel_cet_sss: bool = false;

/// PSFD.
///
/// Indicates bit 7 of the IA32_SPEC_CTRL MSR is supported.
///
/// Bit 7 of this MSR disables Fast Store Forwarding Predictor without disabling Speculative Store Bypass.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[0]
pub var intel_psfd: bool = false;

/// IPRED_CTRL.
///
/// Indicates bits 3 and 4 of the IA32_SPEC_CTRL MSR are supported.
///
/// Bit 3 of this MSR enables IPRED_DIS control for CPL3.
///
/// Bit 4 of this MSR enables IPRED_DIS control for CPL0/1/2.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[1]
pub var intel_ipred_ctrl: bool = false;

/// RRSBA_CTRL.
///
/// Indicates bits 5 and 6 of the IA32_SPEC_CTRL MSR are supported.
///
/// Bit 5 of this MSR disables RRSBA behavior for CPL3.
///
/// Bit 6 of this MSR disables RRSBA behavior for CPL0/1/2.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[2]
pub var intel_rrsba_ctrl: bool = false;

/// DDPD_U.
///
/// Indicates bit 8 of the IA32_SPEC_CTRL MSR is supported.
///
/// Bit 8 of this MSR disables Data Dependent Prefetcher.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[3]
pub var intel_ddpd_u: bool = false;

/// BHI_CTRL.
///
/// Indicates bit 10 of the IA32_SPEC_CTRL MSR is supported.
///
/// Bit 10 of this MSR enables BHI_DIS_S behavior.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[4]
pub var intel_bhi_ctrl: bool = false;

/// MCDT_NO.
///
/// Processors that enumerate this bit as 1 do not exhibit MXCSR Configuration Dependent Timing (MCDT) behavior and do
/// not need to be mitigated to avoid data-dependent behavior for certain instructions.
///
/// Intel Only.
///
/// CPUID.07.02H: EDX[5]
pub var intel_mcdt_no: bool = false;

/// Time Stamp Counter and Nominal Core Crystal Clock Information.
///
/// Intel Only.
///
/// CPUID.15H
pub var intel_tsc_and_crystal_clock_information: ?TscAndCrystalClockInformation = null;

pub const TscAndCrystalClockInformation = struct {
    /// The denominator of the TSC/"core crystal clock" ratio.
    ///
    /// CPUID.15H: EAX
    denominator: u64,

    /// The numerator of the TSC/"core crystal clock" ratio.
    ///
    /// If 0, the TSC/"core crystal clock" ratio is not enumerated.
    ///
    /// CPUID.15H: EBX
    numerator: u64,

    /// The nominal frequency of the core crystal clock in Hz.
    ///
    /// If 0, the nominal core crystal clock frequency is not enumerated.
    ///
    /// The core crystal clock may differ from the reference clock, bus clock, or core clock frequencies.
    ///
    /// CPUID.15H: ECX
    crystal_frequency: u64,
};

/// Processor Frequency Information
///
/// Intel Only.
///
/// CPUID.16H
pub var intel_processor_frequency_information: ?ProcessorFrequencyInformation = null;

pub const ProcessorFrequencyInformation = struct {
    /// The processor base frequency in MHz.
    ///
    /// If 0 this is not supported.
    ///
    /// CPUID.16H: EAX
    processor_base_frequency: u64,

    /// The processor maximum frequency in MHz.
    ///
    /// If 0 this is not supported.
    ///
    /// CPUID.16H: EBX
    processor_max_frequency: u64,

    /// The bus (reference) frequency in MHz.
    ///
    /// If 0 this is not supported.
    ///
    /// CPUID.16H: ECX
    bus_frequency: u64,
};

/// Hypervisor identification string.
///
/// CPUID.40000000H: EBX, ECX, EDX
///
/// See `hypervisorVendor`.
pub var _raw_hypervisor_vendor_string: [12]u8 = [_]u8{0} ** 12;

/// Hypervisor identification string.
///
/// CPUID.40000000H: EBX, ECX, EDX
pub fn hypervisorVendorString() []const u8 {
    return std.mem.sliceTo(&_raw_hypervisor_vendor_string, 0);
}

pub var hypervisor: Hypervisor = .none;

pub const Hypervisor = enum {
    none,

    kvm,
    tcg,
    hyperv,
    vmware,
    xen,
    parallels,
    virtualbox,

    unknown,
};

/// Hypervisor timing information.
///
/// CPUID.40000010H
///
/// https://lore.kernel.org/lkml/1222881242.9381.17.camel@alok-dev1/
pub var hypervisor_timing_information: ?HypervisorTimingInformation = null;

pub const HypervisorTimingInformation = struct {
    /// TSC frequency in KHz.
    tsc_frequency: u64,

    /// Bus (local apic timer) frequency in KHz.
    bus_frequency: u64,
};

/// BrandId.
///
/// This field, in conjunction with CPUID.1: EBX[8BitBrandId], is used by system firmware to generate the processor
/// name string. See your processor revision guide for how to program the processor name string.
///
/// AMD Only.
///
/// CPUID.80000001H: EBX[15:0]
pub var amd_brand_id: ?u16 = null;

/// PkgType.
///
/// AMD Only.
///
/// CPUID.80000001H: EBX[31:28]
pub var amd_pkg_type: ?u4 = null;

/// LAHF/SAHF available in 64-bit mode.
///
/// LAHF and SAHF are always available in other modes, regardless of the enumeration of this feature flag.
///
/// CPUID.80000001H: ECX[0]
pub var lahf_sahf: bool = false;

/// CmpLegacy.
///
/// Core multi-processing legacy mode.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[1]
pub var amd_cmplegacy: bool = false;

/// SVM.
///
/// Secure virtual machine.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[2]
pub var amd_svm: bool = false;

/// Extended APIC space.
///
/// Indicates the presence of extended APIC register space starting at offset 400h from the "APIC Base Address Register"
/// as specified in the BKDG.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[3]
pub var amd_extended_apic: bool = false;

/// AltMovCr8.
///
/// LOCK MOV CR0 means MOV CR8.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[4]
pub var amd_altmovcr8: bool = false;

/// LZCNT.
///
/// CPUID.80000001H: ECX[5]
pub var lzcnt: bool = false;

/// SSE4A.
///
/// EXTRQ, INSERTQ, MOVNTSS, and MOVNTSD instruction support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[6]
pub var amd_sse4a: bool = false;

/// MisAlignSse.
///
/// Misaligned SSE mode.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[7]
pub var amd_misalign_sse: bool = false;

/// PREFETCHW.
///
/// CPUID.80000001H: ECX[8]
pub var prefetchw: bool = false;

/// OS visible workaround.
///
/// Indicates OS-visible workaround support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[9]
pub var amd_osvw: bool = false;

/// IBS.
///
/// Instruction based sampling.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[10]
pub var amd_ibs: bool = false;

/// XOP.
///
/// Extended operation support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[11]
pub var amd_xop: bool = false;

/// SKINIT and STGI are supported.
///
/// Indicates support for SKINIT and STGI, independent of the value of MSRC000_0080[SVME].
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[12]
pub var amd_skinit: bool = false;

/// WDT.
///
/// Watchdog timer support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[13]
pub var amd_wdt: bool = false;

/// LWP.
///
/// Lightweight profiling support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[15]
pub var amd_lwp: bool = false;

/// Four-operand FMA instruction support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[16]
pub var amd_fma4: bool = false;

/// Translation Cache Extension support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[17]
pub var amd_tce: bool = false;

/// Trailing bit manipulation instruction support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[21]
pub var amd_tbm: bool = false;

/// Topology extensions support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[22]
pub var amd_topology_extensions: bool = false;

/// Processor performance counter extensions support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[23]
pub var amd_perfctrextcore: bool = false;

/// NB performance counter extensions support.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[24]
pub var amd_perfctrextnb: bool = false;

/// Data access breakpoint extension.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[26]
pub var amd_databkptext: bool = false;

/// Performance time-stamp counter.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[27]
pub var amd_perftsc: bool = false;

/// Support for L3 performance counter extension.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[28]
pub var amd_perfctrextllc: bool = false;

/// Support for MWAITX and MONITORX instructions.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[29]
pub var amd_monitorx: bool = false;

/// Breakpoint Addressing masking extended to bit 31.
///
/// AMD Only.
///
/// CPUID.80000001H: ECX[30]
pub var amd_addrmaskext: bool = false;

/// SYSCALL/SYSRET.
///
/// Intel processors support SYSCALL and SYSRET only in 64-bit mode.
///
/// CPUID.80000001H: EDX[11]
pub var syscall_sysret: bool = false;

/// Execute Disable.
///
/// CPUID.80000001H: EDX[20]
pub var execute_disable: bool = false;

/// AMD extensions to MMX instructions.
///
/// AMD Only.
///
/// CPUID.80000001H: EDX[22]
pub var amd_mmxext: bool = false;

/// FXSAVE and FXRSTOR instruction optimizations.
///
/// AMD Only.
///
/// CPUID.80000001H: EDX[25]
pub var amd_ffxsr: bool = false;

/// 1-GByte pages
///
/// CPUID.80000001H: EDX[26]
pub var gbyte_pages: bool = false;

/// RDTSCP and IA32_TSC_AUX.
///
/// CPUID.80000001H: EDX[27]
pub var rdtscp: bool = false;

/// Intel 64 Architecture.
///
/// CPUID.80000001H: EDX[29]
pub var @"64bit": bool = false;

/// AMD extensions to 3DNow! instructions.
///
/// AMD Only.
///
/// CPUID.80000001H: EDX[30]
pub var amd_3dnowext: bool = false;

/// 3DNow! instructions.
///
/// AMD Only.
///
/// CPUID.80000001H: EDX[31]
pub var amd_3dnow: bool = false;

/// MCA overflow recovery support.
///
/// If set, indicates that MCA overflow conditions (MCi_STATUS[Overflow]=1) are not fatal; software may safely ignore
/// such conditions.
///
/// If clear, MCA overflow conditions require software to shut down the system.
///
/// CPUID.80000007H: EBX[0]
pub var amd_mcaoverflowrecov: bool = false;

/// Software uncorrectable error containment and recovery capability.
///
/// The processor supports software containment of uncorrectable errors through context synchronizing data poisoning
/// and deferred error interrupts.
///
/// CPUID.80000007H: EBX[1]
pub var amd_succor: bool = false;

/// Hardware assert support.
///
/// Indicates support for MSRC001_10[DF:C0].
///
/// CPUID.80000007H: EBX[2]
pub var amd_hwa: bool = false;

/// 0=MCAX is not supported. 1=MCAX is supported; the MCAX MSR addresses are supported; MCA Extension (MCAX) support.
///
/// Indicates support for MCAX MSRs. MCA_CONFIG[Mcax] is present in all MCA banks.
///
/// CPUID.80000007H: EBX[3]
pub var amd_scalablemca: bool = false;

/// Specifies the ratio of the compute unit power accumulator sample period to the TSC counter period. Returns a value of 0 if not applicable for the system.
///
/// AMD Only.
///
/// CPUID.80000007H: ECX
pub var amd_cpupwrsampletimeratio: ?u32 = null;

/// Temperature sensor.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[0]
pub var amd_ts: bool = false;

/// Frequency ID control. Function replaced by HwPstate.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[1]
pub var amd_fid: bool = false;

/// Voltage ID control. Function replaced by HwPstate.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[2]
pub var amd_vid: bool = false;

/// THERMTRIP.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[3]
pub var amd_ttp: bool = false;

/// Hardware thermal control (HTC).
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[4]
pub var amd_tm: bool = false;

/// 100 MHz multiplier Control.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[6]
pub var amd_100mhzsteps: bool = false;

/// Hardware P-state control.
///
/// MSRC001_0061 [P-state Current Limit], MSRC001_0062 [P-state Control] and MSRC001_0063 [P-state Status] exist.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[7]
pub var amd_hwpstate: bool = false;

/// Invariant TSC.
///
/// CPUID.80000007H: EDX[8]
pub var invariant_tsc: bool = false;

/// Core performance boost.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[9]
pub var amd_cpb: bool = false;

/// Read-only effective frequency interface.
///
/// 1=Indicates presence of MSRC000_00E7 [Read-Only Max Performance Frequency Clock Count (MPerfReadOnly)] and
/// MSRC000_00E8 [Read-Only Actual Performance Frequency Clock Count (APerfReadOnly)].
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[10]
pub var amd_efffreqro: bool = false;

/// Processor feedback interface.
///
/// Value: 1. 1=Indicates support for processor feedback interface.
///
/// Note: This feature is deprecated.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[11]
pub var amd_procfeedbackinterface: bool = false;

/// Processor power reporting interface supported.
///
/// AMD Only.
///
/// CPUID.80000007H: EDX[12]
pub var amd_procpowerreporting: bool = false;

/// Maximum physical address size in bits.
///
///  When this is zero, this field also indicates the maximum guest physical address size.
///
/// CPUID.80000008H: EAX[7:0]
pub var physical_address_size: ?u8 = null;

/// Maximum linear address size in bits.
///
/// CPUID.80000008H: EAX[15:8]
pub var linear_address_size: ?u8 = null;

/// Maximum guest physical address size in bits.
///
/// This number applies only to guests using nested paging. When this field is zero, refer to the
/// `physical_address_size` field for the maximum guest physical address size.
///
/// CPUID.80000008H: EAX[23:16]
pub var guest_physical_address_size: ?u8 = null;

/// CLZERO instruction supported.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[0]
pub var clzero: bool = false;

/// Instruction Retired Counter MSR available.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[1]
pub var instruction_retired_counter_msr: bool = false;

/// FP Error Pointers Restored by XRSTOR.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[2]
pub var fp_error_pointers_restored_by_xrstor: bool = false;

/// INVLPGB and TLBSYNC instruction supported.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[3]
pub var invlpgb: bool = false;

/// RDPRU instruction supported.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[4]
pub var rdpru: bool = false;

/// Bandwidth Enforcement Extension.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[6]
pub var bandwidth_enforcement_extension: bool = false;

/// MCOMMIT instruction supported.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[8]
pub var mcommit: bool = false;

/// WBNOINVD instruction supported.
///
/// CPUID.80000008H: EBX[9]
pub var wbnoinvd: bool = false;

/// Indirect Branch Prediction Barrier.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[12]
pub var indirect_branch_prediction_barrier: bool = false;

/// WBINVD/WBNOINVD are interruptible.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[13]
pub var wbinvd_wbnoinvd_are_interruptible: bool = false;

/// Indirect Branch Restricted Speculation.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[14]
pub var indirect_branch_restricted_speculation: bool = false;

/// Single Thread Indirect Branch Prediction mode.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[15]
pub var single_thread_indirect_branch_prediction_mode: bool = false;

/// Processor prefers that IBRS be left on.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[16]
pub var processor_prefers_that_ibrs_be_left_on: bool = false;

/// Processor prefers that STIBP be left on.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[17]
pub var processor_prefers_that_stibp_be_left_on: bool = false;

/// IBRS is preferred over software solution.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[18]
pub var ibrs_is_preferred_over_software: bool = false;

/// IBRS provides same mode speculation limits.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[19]
pub var ibrs_provides_same_mode_speculation_limits: bool = false;

/// EFER.LMSLE is unsupported.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[20]
pub var efer_lmsle_is_unsupported: bool = false;

/// INVLPGB support for invalidating guest nested translations.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[21]
pub var invlpgb_support_for_invalidating_guest_nested_translations: bool = false;

/// Speculative Store Bypass Disable.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[24]
pub var speculative_store_bypass_disable: bool = false;

/// Use VIRT_SPEC_CTL for SSBD.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[25]
pub var use_virt_spec_ctl_for_ssbd: bool = false;

/// SSBD not needed on this processor.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[26]
pub var ssbd_not_needed: bool = false;

/// Collaborative Processor Performance Control.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[27]
pub var collaborative_processor_performance_control: bool = false;

/// Predictive Store Forward Disable.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[28]
pub var predictive_store_forward_disable: bool = false;

/// The processor is not affected by branch type confusion.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[29]
pub var processor_is_not_affected_by_branch_type_confusion: bool = false;

/// The processor clears the return address predictor when MSR PRED_CMD.IBPB is written to 1.
///
/// AMD Only.
///
/// CPUID.80000008H: EBX[30]
pub var return_address_predictor_cleared_on_ibpb_write: bool = false;

/// Number of physical threads - 1.
///
/// The number of threads in the processor is `physical_threads + 1` (e.g., if `physical_threads` = 0, then there is one
/// thread).
///
/// AMD Only.
///
/// CPUID.80000008H: ECX[7:0]
pub var physical_threads: ?u8 = null;

/// APIC ID size.
///
/// The number of bits in the initial APIC20[ApicId] value that indicate logical processor ID within a package.
/// The size of this field determines the maximum number of logical processors (MNLP) that the package could
/// theoretically support, and not the actual number of logical processors that are implemented or enabled in the
/// package, as indicated by `physical_threads`.
///
/// A value of zero indicates that legacy methods must be used to determine the maximum number of logical processors,
/// as indicated by `physical_threads`.
///
/// ```zig
///     if (apic_id_size == 0) {
///         MNLP = physical_threads + 1;
///     } else {
///         MNLP = (2 raised to the power of apic_id_size);
///     }
/// ```
///
/// AMD Only.
///
/// CPUID.80000008H: ECX[15:12]
pub var apic_id_size: ?u4 = null;

/// Performance time-stamp counter size.
///
/// Indicates the size of MSRC001_0280[PTSC].
///
/// AMD Only.
///
/// CPUID.80000008H: ECX[17:16]
pub var performance_time_stamp_counter_size: ?PerformanceTimeStampCounterSize = null;

pub const PerformanceTimeStampCounterSize = enum(u2) {
    @"40" = 0b00,
    @"48" = 0b01,
    @"56" = 0b10,
    @"64" = 0b11,
};

/// Maximum page count for INVLPGB instruction.
///
/// AMD Only.
///
/// CPUID.80000008H: EDX[15:0]
pub var maximum_page_count_for_invlpgb: ?u16 = null;

/// The maximum ECX value recognized by RDPRU.
///
/// AMD Only.
///
/// CPUID.80000008H: EDX[31:16]
pub var maximum_ecx_value_for_rdpru: ?u16 = null;

const hz_per_khz = 1000;
const hz_per_mhz = 1000000;

/// Attempts to determine the core crystal frequency from CPUID.15H and CPUID.16H.
///
/// The local APIC timer is fed by this clock.
pub fn determineCrystalFrequency() ?u64 {
    const tsc_and_core_crystal_info = intel_tsc_and_crystal_clock_information orelse return null;

    if (tsc_and_core_crystal_info.numerator == 0 or tsc_and_core_crystal_info.denominator == 0) {
        return null;
    }

    var crystal_hz = tsc_and_core_crystal_info.crystal_frequency;

    // TODO: if `crystal_hz` == 0 and model is Denverton SoCs (linux INTEL_FAM6_ATOM_GOLDMONT_D) then crystal is 25MHz

    if (crystal_hz == 0 and intel_processor_frequency_information != null) {
        // use the crystal ratio and the CPU speed to determine the crystal frequency
        const processor_frequency_info = intel_processor_frequency_information.?;

        crystal_hz =
            (processor_frequency_info.processor_base_frequency * hz_per_mhz * tsc_and_core_crystal_info.denominator) /
            tsc_and_core_crystal_info.numerator;
    }

    if (crystal_hz == 0) return null;

    return crystal_hz;
}

/// Attempts to determine the TSC frequency (in Hz) from CPUID.15H, CPUID.16H and CPUID.40000010H.
pub fn determineTscFrequency() ?u64 {
    leaf15_16: {
        const tsc_and_core_crystal_info = intel_tsc_and_crystal_clock_information orelse
            break :leaf15_16;

        const crystal_hz = determineCrystalFrequency() orelse break :leaf15_16;

        return (crystal_hz * tsc_and_core_crystal_info.numerator) /
            tsc_and_core_crystal_info.denominator;
    }

    if (hypervisor_timing_information) |hypervisor_timing_info| {
        return hypervisor_timing_info.tsc_frequency * hz_per_khz;
    }

    return null;
}

/// Captures CPUID.00H.
fn capture00H() void {
    const cpuid_result = raw(0x0, 0);

    max_standard_leaf = cpuid_result.eax;

    const vendor_string_array = [_]u32{ cpuid_result.ebx, cpuid_result.edx, cpuid_result.ecx };
    std.mem.copyForwards(u8, &_raw_cpu_vendor_string, std.mem.sliceAsBytes(&vendor_string_array));
}

fn determineVendor() Vendor {
    const vendor_string = cpuVendorString();

    if (std.mem.eql(u8, vendor_string, "AuthenticAMD")) return .amd;
    if (std.mem.eql(u8, vendor_string, "GenuineIntel")) return .intel;

    return .unknown;
}

/// Captures CPUID.01H.
fn capture01H() void {
    if (max_standard_leaf < 0x01) return;

    const cpuid_result = raw(0x01, 0);

    // EAX
    {
        const Info = packed struct(u32) {
            stepping_id: u4,
            model_id: u4,
            family_id: u4,
            processor_type: ProcessorType,
            _reserved1: u2,
            extended_model_id: u4,
            extended_family_id: u8,
            _reserved2: u4,
        };
        const info: Info = @bitCast(cpuid_result.eax);
        stepping_id = info.stepping_id;
        _raw_model_id = info.model_id;
        _raw_family_id = info.family_id;
        processor_type = info.processor_type;
        _raw_extended_model_id = info.extended_model_id;
        _raw_extended_family_id = info.extended_family_id;
    }

    // EBX
    {
        const Info = packed struct(u32) {
            brand_index: u8,
            clflush_line_size: u8,
            maximum_number_of_addressable_ids: u8,
            initial_apic_id: u8,
        };
        const info: Info = @bitCast(cpuid_result.ebx);
        brand_index = info.brand_index;
        clflush_line_size = info.clflush_line_size;
        maximum_number_of_addressable_ids = info.maximum_number_of_addressable_ids;
    }

    // ECX
    {
        sse3 = bitjuggle.isBitSet(cpuid_result.ecx, 0);
        pclmulqdq = bitjuggle.isBitSet(cpuid_result.ecx, 1);
        if (vendor == .intel) intel_dtes64 = bitjuggle.isBitSet(cpuid_result.ecx, 2);
        monitor = bitjuggle.isBitSet(cpuid_result.ecx, 3);
        if (vendor == .intel) intel_ds_cpl = bitjuggle.isBitSet(cpuid_result.ecx, 4);
        if (vendor == .intel) intel_vmx = bitjuggle.isBitSet(cpuid_result.ecx, 5);
        if (vendor == .intel) intel_smx = bitjuggle.isBitSet(cpuid_result.ecx, 6);
        if (vendor == .intel) intel_eist = bitjuggle.isBitSet(cpuid_result.ecx, 7);
        if (vendor == .intel) intel_tm2 = bitjuggle.isBitSet(cpuid_result.ecx, 8);
        ssse3 = bitjuggle.isBitSet(cpuid_result.ecx, 9);
        if (vendor == .intel) intel_cnxt_id = bitjuggle.isBitSet(cpuid_result.ecx, 10);
        if (vendor == .intel) intel_sdbg = bitjuggle.isBitSet(cpuid_result.ecx, 11);
        fma = bitjuggle.isBitSet(cpuid_result.ecx, 12);
        cmpxchg16b = bitjuggle.isBitSet(cpuid_result.ecx, 13);
        if (vendor == .intel) intel_xtpr_update_control = bitjuggle.isBitSet(cpuid_result.ecx, 14);
        if (vendor == .intel) intel_pdcm = bitjuggle.isBitSet(cpuid_result.ecx, 15);
        // CPUID.01H: ECX[16] reserved
        if (vendor == .intel) intel_pcid = bitjuggle.isBitSet(cpuid_result.ecx, 17);
        if (vendor == .intel) intel_dca = bitjuggle.isBitSet(cpuid_result.ecx, 18);
        sse4_1 = bitjuggle.isBitSet(cpuid_result.ecx, 19);
        sse4_2 = bitjuggle.isBitSet(cpuid_result.ecx, 20);
        x2apic = bitjuggle.isBitSet(cpuid_result.ecx, 21);
        movbe = bitjuggle.isBitSet(cpuid_result.ecx, 22);
        popcnt = bitjuggle.isBitSet(cpuid_result.ecx, 23);
        if (vendor == .intel) intel_tsc_deadline = bitjuggle.isBitSet(cpuid_result.ecx, 24);
        aesni = bitjuggle.isBitSet(cpuid_result.ecx, 25);
        xsave = bitjuggle.isBitSet(cpuid_result.ecx, 26);
        osxsave = bitjuggle.isBitSet(cpuid_result.ecx, 27);
        avx = bitjuggle.isBitSet(cpuid_result.ecx, 28);
        f16c = bitjuggle.isBitSet(cpuid_result.ecx, 29);
        rdrand = bitjuggle.isBitSet(cpuid_result.ecx, 30);
        hypervisor_present = bitjuggle.isBitSet(cpuid_result.ecx, 31);
    }

    // EDX
    {
        fpu = bitjuggle.isBitSet(cpuid_result.edx, 0);
        vme = bitjuggle.isBitSet(cpuid_result.edx, 1);
        de = bitjuggle.isBitSet(cpuid_result.edx, 2);
        pse = bitjuggle.isBitSet(cpuid_result.edx, 3);
        tsc = bitjuggle.isBitSet(cpuid_result.edx, 4);
        msr = bitjuggle.isBitSet(cpuid_result.edx, 5);
        pae = bitjuggle.isBitSet(cpuid_result.edx, 6);
        mce = bitjuggle.isBitSet(cpuid_result.edx, 7);
        cx8 = bitjuggle.isBitSet(cpuid_result.edx, 8);
        apic = bitjuggle.isBitSet(cpuid_result.edx, 9);
        // CPUID.01H: EDX[10] reserved
        sep = bitjuggle.isBitSet(cpuid_result.edx, 11);
        mtrr = bitjuggle.isBitSet(cpuid_result.edx, 12);
        pge = bitjuggle.isBitSet(cpuid_result.edx, 13);
        mca = bitjuggle.isBitSet(cpuid_result.edx, 14);
        cmov = bitjuggle.isBitSet(cpuid_result.edx, 15);
        pat = bitjuggle.isBitSet(cpuid_result.edx, 16);
        pse_36 = bitjuggle.isBitSet(cpuid_result.edx, 17);
        if (vendor == .intel) intel_psn = bitjuggle.isBitSet(cpuid_result.edx, 18);
        clfsh = bitjuggle.isBitSet(cpuid_result.edx, 19);
        // CPUID.01H: EDX[20] reserved
        if (vendor == .intel) intel_ds = bitjuggle.isBitSet(cpuid_result.edx, 21);
        if (vendor == .intel) intel_acpi = bitjuggle.isBitSet(cpuid_result.edx, 22);
        mmx = bitjuggle.isBitSet(cpuid_result.edx, 23);
        fxsr = bitjuggle.isBitSet(cpuid_result.edx, 24);
        sse = bitjuggle.isBitSet(cpuid_result.edx, 25);
        sse2 = bitjuggle.isBitSet(cpuid_result.edx, 26);
        if (vendor == .intel) intel_ss = bitjuggle.isBitSet(cpuid_result.edx, 27);
        htt = bitjuggle.isBitSet(cpuid_result.edx, 28);
        if (vendor == .intel) intel_tm = bitjuggle.isBitSet(cpuid_result.edx, 29);
        // CPUID.01H: EDX[30] reserved
        if (vendor == .intel) intel_pbe = bitjuggle.isBitSet(cpuid_result.edx, 31);
    }
}

/// Captures CPUID.06H.
fn capture06H() void {
    if (max_standard_leaf < 0x06) return;

    const cpuid_result = raw(0x06, 0);

    // EAX
    {
        if (vendor == .intel) intel_digital_temperature_sensor = bitjuggle.isBitSet(cpuid_result.eax, 0);
        if (vendor == .intel) intel_turbo_boost = bitjuggle.isBitSet(cpuid_result.eax, 1);
        arat = bitjuggle.isBitSet(cpuid_result.eax, 2);
        // CPUID.06H: EAX[3] reserved
        if (vendor == .intel) intel_pln = bitjuggle.isBitSet(cpuid_result.eax, 4);
        if (vendor == .intel) intel_ecmd = bitjuggle.isBitSet(cpuid_result.eax, 5);
        if (vendor == .intel) intel_ptm = bitjuggle.isBitSet(cpuid_result.eax, 6);
        if (vendor == .intel) intel_hwp = bitjuggle.isBitSet(cpuid_result.eax, 7);
        if (vendor == .intel) intel_hwp_notification = bitjuggle.isBitSet(cpuid_result.eax, 8);
        if (vendor == .intel) intel_hwp_activity_window = bitjuggle.isBitSet(cpuid_result.eax, 9);
        if (vendor == .intel) intel_hwp_energy_performance_preference = bitjuggle.isBitSet(cpuid_result.eax, 10);
        if (vendor == .intel) intel_hwp_package_level_request = bitjuggle.isBitSet(cpuid_result.eax, 11);
        // CPUID.06H: EAX[12] reserved
        if (vendor == .intel) intel_hdc = bitjuggle.isBitSet(cpuid_result.eax, 13);
        if (vendor == .intel) intel_turbo_boost_3 = bitjuggle.isBitSet(cpuid_result.eax, 14);
        if (vendor == .intel) intel_highest_performance_change = bitjuggle.isBitSet(cpuid_result.eax, 15);
        if (vendor == .intel) intel_hwp_peci_override = bitjuggle.isBitSet(cpuid_result.eax, 16);
        if (vendor == .intel) intel_flexible_hwp = bitjuggle.isBitSet(cpuid_result.eax, 17);
        if (vendor == .intel) intel_fast_ia32_hwp_request = bitjuggle.isBitSet(cpuid_result.eax, 18);
        if (vendor == .intel) intel_hw_feedback = bitjuggle.isBitSet(cpuid_result.eax, 19);
        if (vendor == .intel) intel_ignore_hwp_request = bitjuggle.isBitSet(cpuid_result.eax, 20);
        // CPUID.06H: EAX[21] reserved
        // CPUID.06H: EAX[22] reserved
        if (vendor == .intel) intel_thread_director = bitjuggle.isBitSet(cpuid_result.eax, 23);
        if (vendor == .intel) intel_ia32_therm_interrupt = bitjuggle.isBitSet(cpuid_result.eax, 24);
        // CPUID.06H: EAX[25] reserved
        // CPUID.06H: EAX[26] reserved
        // CPUID.06H: EAX[27] reserved
        // CPUID.06H: EAX[28] reserved
        // CPUID.06H: EAX[29] reserved
        // CPUID.06H: EAX[30] reserved
        // CPUID.06H: EAX[31] reserved
    }

    // EBX
    {
        if (vendor == .intel) intel_digital_thermal_sensor_interrupt_thresholds = bitjuggle.getBits(cpuid_result.ebx, 0, 4);
        // CPUID.06H: EBX[4] reserved
        // CPUID.06H: EBX[5] reserved
        // CPUID.06H: EBX[6] reserved
        // CPUID.06H: EBX[7] reserved
        // CPUID.06H: EBX[8] reserved
        // CPUID.06H: EBX[9] reserved
        // CPUID.06H: EBX[10] reserved
        // CPUID.06H: EBX[11] reserved
        // CPUID.06H: EBX[12] reserved
        // CPUID.06H: EBX[13] reserved
        // CPUID.06H: EBX[14] reserved
        // CPUID.06H: EBX[15] reserved
        // CPUID.06H: EBX[16] reserved
        // CPUID.06H: EBX[17] reserved
        // CPUID.06H: EBX[18] reserved
        // CPUID.06H: EBX[19] reserved
        // CPUID.06H: EBX[20] reserved
        // CPUID.06H: EBX[21] reserved
        // CPUID.06H: EBX[22] reserved
        // CPUID.06H: EBX[23] reserved
        // CPUID.06H: EBX[24] reserved
        // CPUID.06H: EBX[25] reserved
        // CPUID.06H: EBX[26] reserved
        // CPUID.06H: EBX[27] reserved
        // CPUID.06H: EBX[28] reserved
        // CPUID.06H: EBX[29] reserved
        // CPUID.06H: EBX[30] reserved
        // CPUID.06H: EBX[31] reserved
    }

    // ECX
    {
        ia32_mperf_ia32_aperf = bitjuggle.isBitSet(cpuid_result.ecx, 0);
        // CPUID.06H: ECX[1] reserved
        // CPUID.06H: ECX[2] reserved
        if (vendor == .intel) intel_ia32_energy_perf_bias = bitjuggle.isBitSet(cpuid_result.ecx, 3);
        // CPUID.06H: ECX[4] reserved
        // CPUID.06H: ECX[5] reserved
        // CPUID.06H: ECX[6] reserved
        // CPUID.06H: ECX[7] reserved
        if (vendor == .intel) intel_thread_director_classes_supported = bitjuggle.getBits(cpuid_result.ecx, 8, 8);
        // CPUID.06H: ECX[16] reserved
        // CPUID.06H: ECX[17] reserved
        // CPUID.06H: ECX[18] reserved
        // CPUID.06H: ECX[19] reserved
        // CPUID.06H: ECX[20] reserved
        // CPUID.06H: ECX[21] reserved
        // CPUID.06H: ECX[22] reserved
        // CPUID.06H: ECX[23] reserved
        // CPUID.06H: ECX[24] reserved
        // CPUID.06H: ECX[25] reserved
        // CPUID.06H: ECX[26] reserved
        // CPUID.06H: ECX[27] reserved
        // CPUID.06H: ECX[28] reserved
        // CPUID.06H: ECX[29] reserved
        // CPUID.06H: ECX[30] reserved
        // CPUID.06H: ECX[31] reserved
    }

    // EDX
    {
        if (vendor == .intel) intel_performance_capability_reporting = bitjuggle.isBitSet(cpuid_result.edx, 0);
        if (vendor == .intel) intel_energy_efficiency_capability_reporting = bitjuggle.isBitSet(cpuid_result.edx, 1);
        // CPUID.06H: EDX[2] reserved
        // CPUID.06H: EDX[3] reserved
        // CPUID.06H: EDX[4] reserved
        // CPUID.06H: EDX[5] reserved
        // CPUID.06H: EDX[6] reserved
        // CPUID.06H: EDX[7] reserved
        if (vendor == .intel) intel_hardware_feedback_interface_size = @as(u5, bitjuggle.getBits(cpuid_result.edx, 8, 4)) + 1;
        // CPUID.06H: EDX[12] reserved
        // CPUID.06H: EDX[13] reserved
        // CPUID.06H: EDX[14] reserved
        // CPUID.06H: EDX[15] reserved
        // CPUID.06H: EDX[16] reserved
        // CPUID.06H: EDX[17] reserved
        // CPUID.06H: EDX[18] reserved
        // CPUID.06H: EDX[19] reserved
        // CPUID.06H: EDX[20] reserved
        // CPUID.06H: EDX[21] reserved
        // CPUID.06H: EDX[22] reserved
        // CPUID.06H: EDX[23] reserved
        // CPUID.06H: EDX[24] reserved
        // CPUID.06H: EDX[25] reserved
        // CPUID.06H: EDX[26] reserved
        // CPUID.06H: EDX[27] reserved
        // CPUID.06H: EDX[28] reserved
        // CPUID.06H: EDX[29] reserved
        // CPUID.06H: EDX[30] reserved
        // CPUID.06H: EDX[31] reserved
    }
}

/// Captures CPUID.07H.
fn capture07H() void {
    if (max_standard_leaf < 0x07) return;

    const subleaf0 = raw(0x07, 0);

    max_07_subleaf = subleaf0.eax;

    // subleaf 0 EBX
    {
        fsgsbase = bitjuggle.isBitSet(subleaf0.ebx, 0);
        if (vendor == .intel) intel_ia32_tsc_adjust = bitjuggle.isBitSet(subleaf0.ebx, 1);
        if (vendor == .intel) intel_sgx = bitjuggle.isBitSet(subleaf0.ebx, 2);
        bmi1 = bitjuggle.isBitSet(subleaf0.ebx, 3);
        if (vendor == .intel) intel_hle = bitjuggle.isBitSet(subleaf0.ebx, 4);
        avx2 = bitjuggle.isBitSet(subleaf0.ebx, 5);
        if (vendor == .intel) intel_fdp_excptn_only = bitjuggle.isBitSet(subleaf0.ebx, 6);
        smep = bitjuggle.isBitSet(subleaf0.ebx, 7);
        bmi2 = bitjuggle.isBitSet(subleaf0.ebx, 8);
        if (vendor == .intel) intel_enhanced_repmovsb = bitjuggle.isBitSet(subleaf0.ebx, 9);
        invpcid = bitjuggle.isBitSet(subleaf0.ebx, 10);
        if (vendor == .intel) intel_rtm = bitjuggle.isBitSet(subleaf0.ebx, 11);

        if (vendor == .intel) intel_rdt_m = bitjuggle.isBitSet(subleaf0.ebx, 12);
        if (vendor == .amd) amd_pqm = bitjuggle.isBitSet(subleaf0.ebx, 12);

        if (vendor == .intel) intel_deprecate_fpu_cs_ds = bitjuggle.isBitSet(subleaf0.ebx, 13);
        if (vendor == .intel) intel_mpx = bitjuggle.isBitSet(subleaf0.ebx, 14);

        if (vendor == .intel) intel_rdt_a = bitjuggle.isBitSet(subleaf0.ebx, 15);
        if (vendor == .amd) amd_pqe = bitjuggle.isBitSet(subleaf0.ebx, 15);

        if (vendor == .intel) intel_avx512f = bitjuggle.isBitSet(subleaf0.ebx, 16);
        if (vendor == .intel) intel_avx512dq = bitjuggle.isBitSet(subleaf0.ebx, 17);
        rdseed = bitjuggle.isBitSet(subleaf0.ebx, 18);
        adx = bitjuggle.isBitSet(subleaf0.ebx, 19);
        smap = bitjuggle.isBitSet(subleaf0.ebx, 20);
        if (vendor == .intel) intel_avx512_ifma = bitjuggle.isBitSet(subleaf0.ebx, 21);
        clflushopt = bitjuggle.isBitSet(subleaf0.ebx, 23);
        clwb = bitjuggle.isBitSet(subleaf0.ebx, 24);
        intel_processor_trace = bitjuggle.isBitSet(subleaf0.ebx, 25);
        if (vendor == .intel) intel_avx512pf = bitjuggle.isBitSet(subleaf0.ebx, 26);
        if (vendor == .intel) intel_avx512er = bitjuggle.isBitSet(subleaf0.ebx, 27);
        if (vendor == .intel) intel_avx512cd = bitjuggle.isBitSet(subleaf0.ebx, 28);
        sha = bitjuggle.isBitSet(subleaf0.ebx, 29);
        if (vendor == .intel) intel_avx512bw = bitjuggle.isBitSet(subleaf0.ebx, 30);
        if (vendor == .intel) intel_avx512vl = bitjuggle.isBitSet(subleaf0.ebx, 31);
    }

    // subleaf 0 ECX
    {
        if (vendor == .intel) intel_prefetchwt1 = bitjuggle.isBitSet(subleaf0.ecx, 0);
        if (vendor == .intel) intel_avx512_vbmi = bitjuggle.isBitSet(subleaf0.ecx, 1);
        umip = bitjuggle.isBitSet(subleaf0.ecx, 2);
        pku = bitjuggle.isBitSet(subleaf0.ecx, 3);
        // Provided by `ospke`
        if (vendor == .intel) intel_waitpkg = bitjuggle.isBitSet(subleaf0.ecx, 5);
        if (vendor == .intel) intel_avx512_vbmi2 = bitjuggle.isBitSet(subleaf0.ecx, 6);
        cet_ss = bitjuggle.isBitSet(subleaf0.ecx, 7);
        if (vendor == .intel) intel_gfni = bitjuggle.isBitSet(subleaf0.ecx, 8);
        vaes = bitjuggle.isBitSet(subleaf0.ecx, 9);
        vpclmulqdq = bitjuggle.isBitSet(subleaf0.ecx, 10);
        if (vendor == .intel) intel_avx512_vnni = bitjuggle.isBitSet(subleaf0.ecx, 11);
        if (vendor == .intel) intel_avx512_bitalg = bitjuggle.isBitSet(subleaf0.ecx, 12);
        if (vendor == .intel) intel_tme_en = bitjuggle.isBitSet(subleaf0.ecx, 13);
        if (vendor == .intel) intel_avx512_vpopcntdq = bitjuggle.isBitSet(subleaf0.ecx, 14);
        // CPUID.07.00H: ECX[15] reserved
        la57 = bitjuggle.isBitSet(subleaf0.ecx, 16);
        if (vendor == .intel) intel_mawau = bitjuggle.getBits(subleaf0.ecx, 17, 5);
        rdpid = bitjuggle.isBitSet(subleaf0.ecx, 22);
        if (vendor == .intel) intel_kl = bitjuggle.isBitSet(subleaf0.ecx, 23);
        // Provided by `busLockDetect`
        if (vendor == .intel) intel_cldemote = bitjuggle.isBitSet(subleaf0.ecx, 25);
        // CPUID.07.00H: ECX[26] reserved
        if (vendor == .intel) intel_movdiri = bitjuggle.isBitSet(subleaf0.ecx, 27);
        if (vendor == .intel) intel_movdir64b = bitjuggle.isBitSet(subleaf0.ecx, 28);
        if (vendor == .intel) intel_enqcmd = bitjuggle.isBitSet(subleaf0.ecx, 29);
        if (vendor == .intel) intel_sgx_lc = bitjuggle.isBitSet(subleaf0.ecx, 30);
        if (vendor == .intel) intel_pks = bitjuggle.isBitSet(subleaf0.ecx, 31);
    }

    // subleaf 0 EDX
    {
        // CPUID.07.00H: EDX[0] reserved
        if (vendor == .intel) intel_sgx_keys = bitjuggle.isBitSet(subleaf0.edx, 1);
        if (vendor == .intel) intel_avx512_4vnniw = bitjuggle.isBitSet(subleaf0.edx, 2);
        if (vendor == .intel) intel_avx512_4fmaps = bitjuggle.isBitSet(subleaf0.edx, 3);
        if (vendor == .intel) intel_fast_short_rep_mov = bitjuggle.isBitSet(subleaf0.edx, 4);
        if (vendor == .intel) intel_uintr = bitjuggle.isBitSet(subleaf0.edx, 5);
        // CPUID.07.00H: EDX[6] reserved
        // CPUID.07.00H: EDX[7] reserved
        if (vendor == .intel) intel_avx512_vp2intersect = bitjuggle.isBitSet(subleaf0.edx, 8);
        if (vendor == .intel) intel_srbds_ctrl = bitjuggle.isBitSet(subleaf0.edx, 9);
        if (vendor == .intel) intel_md_clear = bitjuggle.isBitSet(subleaf0.edx, 10);
        if (vendor == .intel) intel_rtm_always_abort = bitjuggle.isBitSet(subleaf0.edx, 11);
        // CPUID.07.00H: EDX[12] reserved
        if (vendor == .intel) intel_rtm_force_abort = bitjuggle.isBitSet(subleaf0.edx, 13);
        if (vendor == .intel) intel_serialize = bitjuggle.isBitSet(subleaf0.edx, 14);
        if (vendor == .intel) intel_hybrid = bitjuggle.isBitSet(subleaf0.edx, 15);
        if (vendor == .intel) intel_tsxldtrk = bitjuggle.isBitSet(subleaf0.edx, 16);
        // CPUID.07.00H: EDX[17] reserved
        if (vendor == .intel) intel_pconfig = bitjuggle.isBitSet(subleaf0.edx, 18);
        if (vendor == .intel) intel_architectural_lbrs = bitjuggle.isBitSet(subleaf0.edx, 19);
        if (vendor == .intel) intel_cet_ibt = bitjuggle.isBitSet(subleaf0.edx, 20);
        // CPUID.07.00H: EDX[21] reserved
        if (vendor == .intel) intel_amx_bf16 = bitjuggle.isBitSet(subleaf0.edx, 22);
        if (vendor == .intel) intel_avx512_fp16 = bitjuggle.isBitSet(subleaf0.edx, 23);
        if (vendor == .intel) intel_amx_tile = bitjuggle.isBitSet(subleaf0.edx, 24);
        if (vendor == .intel) intel_amx_int8 = bitjuggle.isBitSet(subleaf0.edx, 25);
        if (vendor == .intel) intel_ibrs_ibpb = bitjuggle.isBitSet(subleaf0.edx, 26);
        if (vendor == .intel) intel_stibp = bitjuggle.isBitSet(subleaf0.edx, 27);
        if (vendor == .intel) intel_l1d_flush = bitjuggle.isBitSet(subleaf0.edx, 28);
        if (vendor == .intel) intel_ia32_arch_capabilities = bitjuggle.isBitSet(subleaf0.edx, 29);
        if (vendor == .intel) intel_ia32_core_capabilities = bitjuggle.isBitSet(subleaf0.edx, 30);
        if (vendor == .intel) intel_ssbd = bitjuggle.isBitSet(subleaf0.edx, 31);
    }

    if (max_07_subleaf < 0x1) return;

    const subleaf1 = raw(0x07, 0x1);

    // subleaf 1 EAX
    {
        // CPUID.07.01H: EAX[0] reserved
        // CPUID.07.01H: EAX[1] reserved
        // CPUID.07.01H: EAX[2] reserved
        // CPUID.07.01H: EAX[3] reserved
        if (vendor == .intel) intel_avx_vnni = bitjuggle.isBitSet(subleaf1.eax, 4);
        if (vendor == .intel) intel_avx512_bf16 = bitjuggle.isBitSet(subleaf1.eax, 5);
        // CPUID.07.01H: EAX[6] reserved
        // CPUID.07.01H: EAX[7] reserved
        // CPUID.07.01H: EAX[8] reserved
        // CPUID.07.01H: EAX[9] reserved
        if (vendor == .intel) intel_fast_zero_length_repmovsb = bitjuggle.isBitSet(subleaf1.eax, 10);
        if (vendor == .intel) intel_fast_short_repstosb = bitjuggle.isBitSet(subleaf1.eax, 11);
        if (vendor == .intel) intel_fast_short_repcmpsb = bitjuggle.isBitSet(subleaf1.eax, 12);
        // CPUID.07.01H: EAX[13] reserved
        // CPUID.07.01H: EAX[14] reserved
        // CPUID.07.01H: EAX[15] reserved
        // CPUID.07.01H: EAX[16] reserved
        // CPUID.07.01H: EAX[17] reserved
        // CPUID.07.01H: EAX[18] reserved
        // CPUID.07.01H: EAX[19] reserved
        // CPUID.07.01H: EAX[20] reserved
        // CPUID.07.01H: EAX[21] reserved
        if (vendor == .intel) intel_hreset = bitjuggle.isBitSet(subleaf1.eax, 22);
        // CPUID.07.01H: EAX[23] reserved
        // CPUID.07.01H: EAX[24] reserved
        // CPUID.07.01H: EAX[25] reserved
        // CPUID.07.01H: EAX[26] reserved
        // CPUID.07.01H: EAX[27] reserved
        // CPUID.07.01H: EAX[28] reserved
        // CPUID.07.01H: EAX[29] reserved
        if (vendor == .intel) intel_invd_disable_post_bios_done = bitjuggle.isBitSet(subleaf1.eax, 30);
        // CPUID.07.01H: EAX[31] reserved
    }

    // subleaf 1 EBX
    {
        if (vendor == .intel) intel_ia32_ppin = bitjuggle.isBitSet(subleaf1.ebx, 0);
        // CPUID.07.01H: EBX[1] reserved
        // CPUID.07.01H: EBX[2] reserved
        // CPUID.07.01H: EBX[3] reserved
        // CPUID.07.01H: EBX[4] reserved
        // CPUID.07.01H: EBX[5] reserved
        // CPUID.07.01H: EBX[6] reserved
        // CPUID.07.01H: EBX[7] reserved
        // CPUID.07.01H: EBX[8] reserved
        // CPUID.07.01H: EBX[9] reserved
        // CPUID.07.01H: EBX[10] reserved
        // CPUID.07.01H: EBX[11] reserved
        // CPUID.07.01H: EBX[12] reserved
        // CPUID.07.01H: EBX[13] reserved
        // CPUID.07.01H: EBX[14] reserved
        // CPUID.07.01H: EBX[15] reserved
        // CPUID.07.01H: EBX[16] reserved
        // CPUID.07.01H: EBX[17] reserved
        // CPUID.07.01H: EBX[18] reserved
        // CPUID.07.01H: EBX[19] reserved
        // CPUID.07.01H: EBX[20] reserved
        // CPUID.07.01H: EBX[21] reserved
        // CPUID.07.01H: EBX[22] reserved
        // CPUID.07.01H: EBX[23] reserved
        // CPUID.07.01H: EBX[24] reserved
        // CPUID.07.01H: EBX[25] reserved
        // CPUID.07.01H: EBX[26] reserved
        // CPUID.07.01H: EBX[27] reserved
        // CPUID.07.01H: EBX[28] reserved
        // CPUID.07.01H: EBX[29] reserved
        // CPUID.07.01H: EBX[30] reserved
        // CPUID.07.01H: EBX[31] reserved
    }

    // subleaf 1 ECX reserved

    // subleaf 1 EDX
    {
        // CPUID.07.01H: EDX[0] reserved
        // CPUID.07.01H: EDX[1] reserved
        // CPUID.07.01H: EDX[2] reserved
        // CPUID.07.01H: EDX[3] reserved
        // CPUID.07.01H: EDX[4] reserved
        // CPUID.07.01H: EDX[5] reserved
        // CPUID.07.01H: EDX[6] reserved
        // CPUID.07.01H: EDX[7] reserved
        // CPUID.07.01H: EDX[8] reserved
        // CPUID.07.01H: EDX[9] reserved
        // CPUID.07.01H: EDX[10] reserved
        // CPUID.07.01H: EDX[11] reserved
        // CPUID.07.01H: EDX[12] reserved
        // CPUID.07.01H: EDX[13] reserved
        // CPUID.07.01H: EDX[14] reserved
        // CPUID.07.01H: EDX[15] reserved
        // CPUID.07.01H: EDX[16] reserved
        // CPUID.07.01H: EDX[17] reserved
        if (vendor == .intel) intel_cet_sss = bitjuggle.isBitSet(subleaf1.edx, 18);
        // CPUID.07.01H: EDX[19] reserved
        // CPUID.07.01H: EDX[20] reserved
        // CPUID.07.01H: EDX[21] reserved
        // CPUID.07.01H: EDX[22] reserved
        // CPUID.07.01H: EDX[23] reserved
        // CPUID.07.01H: EDX[24] reserved
        // CPUID.07.01H: EDX[25] reserved
        // CPUID.07.01H: EDX[26] reserved
        // CPUID.07.01H: EDX[27] reserved
        // CPUID.07.01H: EDX[28] reserved
        // CPUID.07.01H: EDX[29] reserved
        // CPUID.07.01H: EDX[30] reserved
        // CPUID.07.01H: EDX[31] reserved
    }

    if (max_07_subleaf < 0x2) return;

    const subleaf2 = raw(0x07, 0x2);

    // subleaf 2 EAX reserved
    // subleaf 2 EBX reserved
    // subleaf 2 ECX reserved

    // subleaf 2 EDX
    {
        if (vendor == .intel) intel_psfd = bitjuggle.isBitSet(subleaf2.edx, 0);
        if (vendor == .intel) intel_ipred_ctrl = bitjuggle.isBitSet(subleaf2.edx, 1);
        if (vendor == .intel) intel_rrsba_ctrl = bitjuggle.isBitSet(subleaf2.edx, 2);
        if (vendor == .intel) intel_ddpd_u = bitjuggle.isBitSet(subleaf2.edx, 3);
        if (vendor == .intel) intel_bhi_ctrl = bitjuggle.isBitSet(subleaf2.edx, 4);
        if (vendor == .intel) intel_mcdt_no = bitjuggle.isBitSet(subleaf2.edx, 5);
        // CPUID.07.02H: EDX[6] reserved
        // CPUID.07.02H: EDX[7] reserved
        // CPUID.07.02H: EDX[8] reserved
        // CPUID.07.02H: EDX[9] reserved
        // CPUID.07.02H: EDX[10] reserved
        // CPUID.07.02H: EDX[11] reserved
        // CPUID.07.02H: EDX[12] reserved
        // CPUID.07.02H: EDX[13] reserved
        // CPUID.07.02H: EDX[14] reserved
        // CPUID.07.02H: EDX[15] reserved
        // CPUID.07.02H: EDX[16] reserved
        // CPUID.07.02H: EDX[17] reserved
        // CPUID.07.02H: EDX[18] reserved
        // CPUID.07.02H: EDX[19] reserved
        // CPUID.07.02H: EDX[20] reserved
        // CPUID.07.02H: EDX[21] reserved
        // CPUID.07.02H: EDX[22] reserved
        // CPUID.07.02H: EDX[23] reserved
        // CPUID.07.02H: EDX[24] reserved
        // CPUID.07.02H: EDX[25] reserved
        // CPUID.07.02H: EDX[26] reserved
        // CPUID.07.02H: EDX[27] reserved
        // CPUID.07.02H: EDX[28] reserved
        // CPUID.07.02H: EDX[29] reserved
        // CPUID.07.02H: EDX[30] reserved
        // CPUID.07.02H: EDX[31] reserved
    }
}

/// Captures CPUID.15H.
fn capture15H() void {
    if (max_standard_leaf < 0x15) return;

    const cpuid_result = raw(0x15, 0);

    intel_tsc_and_crystal_clock_information = .{
        .denominator = cpuid_result.eax,
        .numerator = cpuid_result.ebx,
        .crystal_frequency = cpuid_result.ecx,
    };
}

/// Captures CPUID.16H.
fn capture16H() void {
    if (max_standard_leaf < 0x16) return;

    const cpuid_result = raw(0x16, 0);

    intel_processor_frequency_information = .{
        .processor_base_frequency = cpuid_result.eax,
        .processor_max_frequency = cpuid_result.ebx,
        .bus_frequency = cpuid_result.ecx,
    };
}

/// Captures CPUID.40000000H.
fn capture40000000H() void {
    const cpuid_result = raw(0x40000000, 0);

    max_hypervisor_leaf = cpuid_result.eax;

    const hypervisor_vendor_array = [_]u32{ cpuid_result.ebx, cpuid_result.ecx, cpuid_result.edx };
    std.mem.copyForwards(u8, &_raw_hypervisor_vendor_string, std.mem.sliceAsBytes(&hypervisor_vendor_array));
}

/// Captures CPUID.40000010H.
///
/// Timing Information.
///
/// Originally defined by VMware, now provided by other hypervisors as well:
///  - VMware
///  - KVM
fn capture40000010H() void {
    if (max_hypervisor_leaf < 0x40000010) return;
    switch (hypervisor) { // TODO: Do other hypervisors support this?
        .vmware, .kvm => {},
        else => return,
    }

    const cpuid_result = raw(0x40000010, 0);

    hypervisor_timing_information = .{
        .tsc_frequency = cpuid_result.eax,
        .bus_frequency = cpuid_result.ebx,
    };
}

fn determineHypervisor() Hypervisor {
    const vendor_string = hypervisorVendorString();

    if (std.mem.startsWith(u8, vendor_string, "KVMKVMKVM")) return .kvm;
    if (std.mem.startsWith(u8, vendor_string, "TCGTCGTCGTCG")) return .tcg;
    if (std.mem.startsWith(u8, vendor_string, "VMwareVMware")) return .vmware;
    if (std.mem.startsWith(u8, vendor_string, "Microsoft Hv")) return .hyperv;
    if (std.mem.startsWith(u8, vendor_string, "XenVMMXenVMM")) return .xen;
    if (std.mem.startsWith(u8, vendor_string, "prl hyperv")) return .parallels;
    if (std.mem.startsWith(u8, vendor_string, "VBoxVBoxVBox")) return .virtualbox;

    return .unknown;
}

/// Captures CPUID.80000000H.
fn capture80000000H() void {
    const cpuid_result = raw(0x80000000, 0);
    max_extended_leaf = cpuid_result.eax;

    // EBX reserved
    // ECX reserved
    // EDX reserved
}

/// Captures CPUID.80000001H.
fn capture80000001H() void {
    if (max_extended_leaf < 0x80000001) return;

    const cpuid_result = raw(0x80000001, 0);

    // EAX reserved

    // EBX
    {
        if (vendor == .amd) amd_brand_id = bitjuggle.getBits(cpuid_result.ebx, 0, 16);
        // CPUID.80000001H: EBX[16] reserved
        // CPUID.80000001H: EBX[17] reserved
        // CPUID.80000001H: EBX[18] reserved
        // CPUID.80000001H: EBX[19] reserved
        // CPUID.80000001H: EBX[20] reserved
        // CPUID.80000001H: EBX[21] reserved
        // CPUID.80000001H: EBX[22] reserved
        // CPUID.80000001H: EBX[23] reserved
        // CPUID.80000001H: EBX[24] reserved
        // CPUID.80000001H: EBX[25] reserved
        // CPUID.80000001H: EBX[26] reserved
        // CPUID.80000001H: EBX[27] reserved
        if (vendor == .amd and processorFamilyId() >= 0x10) amd_pkg_type = bitjuggle.getBits(cpuid_result.ebx, 28, 4);
    }

    // ECX
    {
        lahf_sahf = bitjuggle.isBitSet(cpuid_result.ecx, 0);
        if (vendor == .amd) amd_cmplegacy = bitjuggle.isBitSet(cpuid_result.ecx, 1);
        if (vendor == .amd) amd_svm = bitjuggle.isBitSet(cpuid_result.ecx, 2);
        if (vendor == .amd) amd_extended_apic = bitjuggle.isBitSet(cpuid_result.ecx, 3);
        if (vendor == .amd) amd_altmovcr8 = bitjuggle.isBitSet(cpuid_result.ecx, 4);
        lzcnt = bitjuggle.isBitSet(cpuid_result.ecx, 5);
        if (vendor == .amd) amd_sse4a = bitjuggle.isBitSet(cpuid_result.ecx, 6);
        if (vendor == .amd) amd_misalign_sse = bitjuggle.isBitSet(cpuid_result.ecx, 7);
        prefetchw = bitjuggle.isBitSet(cpuid_result.ecx, 8);
        if (vendor == .amd) amd_osvw = bitjuggle.isBitSet(cpuid_result.ecx, 9);
        if (vendor == .amd) amd_ibs = bitjuggle.isBitSet(cpuid_result.ecx, 10);
        if (vendor == .amd) amd_xop = bitjuggle.isBitSet(cpuid_result.ecx, 11);
        if (vendor == .amd) amd_skinit = bitjuggle.isBitSet(cpuid_result.ecx, 12);
        if (vendor == .amd) amd_wdt = bitjuggle.isBitSet(cpuid_result.ecx, 13);
        // CPUID.80000001H: ECX[14] reserved
        if (vendor == .amd) amd_lwp = bitjuggle.isBitSet(cpuid_result.ecx, 15);
        if (vendor == .amd) amd_fma4 = bitjuggle.isBitSet(cpuid_result.ecx, 16);
        if (vendor == .amd) amd_tce = bitjuggle.isBitSet(cpuid_result.ecx, 17);
        // CPUID.80000001H: ECX[18] reserved
        // CPUID.80000001H: ECX[19] reserved
        // CPUID.80000001H: ECX[20] reserved
        if (vendor == .amd) amd_tbm = bitjuggle.isBitSet(cpuid_result.ecx, 21);
        if (vendor == .amd) amd_topology_extensions = bitjuggle.isBitSet(cpuid_result.ecx, 22);
        if (vendor == .amd) amd_perfctrextcore = bitjuggle.isBitSet(cpuid_result.ecx, 23);
        if (vendor == .amd) amd_perfctrextnb = bitjuggle.isBitSet(cpuid_result.ecx, 24);
        // CPUID.80000001H: ECX[25] reserved
        if (vendor == .amd) amd_databkptext = bitjuggle.isBitSet(cpuid_result.ecx, 26);
        if (vendor == .amd) amd_perftsc = bitjuggle.isBitSet(cpuid_result.ecx, 27);
        if (vendor == .amd) amd_perfctrextllc = bitjuggle.isBitSet(cpuid_result.ecx, 28);
        if (vendor == .amd) amd_monitorx = bitjuggle.isBitSet(cpuid_result.ecx, 29);
        if (vendor == .amd) amd_addrmaskext = bitjuggle.isBitSet(cpuid_result.ecx, 30);
        // CPUID.80000001H: ECX[31] reserved
    }

    // EDX
    {
        // CPUID.80000001H: EDX[0] reserved
        // CPUID.80000001H: EDX[1] reserved
        // CPUID.80000001H: EDX[2] reserved
        // CPUID.80000001H: EDX[3] reserved
        // CPUID.80000001H: EDX[4] reserved
        // CPUID.80000001H: EDX[5] reserved
        // CPUID.80000001H: EDX[6] reserved
        // CPUID.80000001H: EDX[7] reserved
        // CPUID.80000001H: EDX[8] reserved
        // CPUID.80000001H: EDX[9] reserved
        // CPUID.80000001H: EDX[10] reserved
        syscall_sysret = bitjuggle.isBitSet(cpuid_result.edx, 11);
        // CPUID.80000001H: EDX[12] reserved
        // CPUID.80000001H: EDX[13] reserved
        // CPUID.80000001H: EDX[14] reserved
        // CPUID.80000001H: EDX[15] reserved
        // CPUID.80000001H: EDX[16] reserved
        // CPUID.80000001H: EDX[17] reserved
        // CPUID.80000001H: EDX[18] reserved
        // CPUID.80000001H: EDX[19] reserved
        execute_disable = bitjuggle.isBitSet(cpuid_result.edx, 20);
        // CPUID.80000001H: EDX[21] reserved
        if (vendor == .amd) amd_mmxext = bitjuggle.isBitSet(cpuid_result.edx, 22);
        // CPUID.80000001H: EDX[23] reserved
        // CPUID.80000001H: EDX[24] reserved
        if (vendor == .amd) amd_ffxsr = bitjuggle.isBitSet(cpuid_result.edx, 25);
        gbyte_pages = bitjuggle.isBitSet(cpuid_result.edx, 26);
        rdtscp = bitjuggle.isBitSet(cpuid_result.edx, 27);
        // CPUID.80000001H: EDX[28] reserved
        @"64bit" = bitjuggle.isBitSet(cpuid_result.edx, 29);
        if (vendor == .amd) amd_3dnowext = bitjuggle.isBitSet(cpuid_result.edx, 30);
        if (vendor == .amd) amd_3dnow = bitjuggle.isBitSet(cpuid_result.edx, 31);
    }
}

/// Captures the brand string from CPUID.80000002H - CPUID.80000004H
fn capture80000002H_80000004H() void {
    if (max_extended_leaf < 0x80000004) return;

    var brand_string_array: [12]u32 = [_]u32{0} ** 12;
    var i: usize = 0;

    for (0x80000002..0x80000004) |leaf| {
        const leaf_value = raw(@truncate(leaf), 0);

        brand_string_array[i] = leaf_value.eax;
        i += 1;
        brand_string_array[i] = leaf_value.ebx;
        i += 1;
        brand_string_array[i] = leaf_value.ecx;
        i += 1;
        brand_string_array[i] = leaf_value.edx;
        i += 1;
    }

    std.mem.copyForwards(
        u8,
        &_raw_processor_brand_string,
        std.mem.sliceAsBytes(&brand_string_array),
    );
}

/// Captures CPUID.80000007H.
fn capture80000007H() void {
    if (max_extended_leaf < 0x80000007) return;

    const cpuid_result = raw(0x80000007, 0);

    // EAX reserved

    // EBX
    {
        if (vendor == .amd) amd_addrmaskext = bitjuggle.isBitSet(cpuid_result.ebx, 0);
        if (vendor == .amd) amd_succor = bitjuggle.isBitSet(cpuid_result.ebx, 1);
        if (vendor == .amd) amd_hwa = bitjuggle.isBitSet(cpuid_result.ebx, 2);
        if (vendor == .amd) amd_scalablemca = bitjuggle.isBitSet(cpuid_result.ebx, 3);
        // CPUID.80000007H: EBX[4] reserved
        // CPUID.80000007H: EBX[5] reserved
        // CPUID.80000007H: EBX[6] reserved
        // CPUID.80000007H: EBX[7] reserved
        // CPUID.80000007H: EBX[8] reserved
        // CPUID.80000007H: EBX[9] reserved
        // CPUID.80000007H: EBX[10] reserved
        // CPUID.80000007H: EBX[11] reserved
        // CPUID.80000007H: EBX[12] reserved
        // CPUID.80000007H: EBX[13] reserved
        // CPUID.80000007H: EBX[14] reserved
        // CPUID.80000007H: EBX[15] reserved
        // CPUID.80000007H: EBX[16] reserved
        // CPUID.80000007H: EBX[17] reserved
        // CPUID.80000007H: EBX[18] reserved
        // CPUID.80000007H: EBX[19] reserved
        // CPUID.80000007H: EBX[20] reserved
        // CPUID.80000007H: EBX[21] reserved
        // CPUID.80000007H: EBX[22] reserved
        // CPUID.80000007H: EBX[23] reserved
        // CPUID.80000007H: EBX[24] reserved
        // CPUID.80000007H: EBX[25] reserved
        // CPUID.80000007H: EBX[26] reserved
        // CPUID.80000007H: EBX[27] reserved
        // CPUID.80000007H: EBX[28] reserved
        // CPUID.80000007H: EBX[29] reserved
        // CPUID.80000007H: EBX[30] reserved
        // CPUID.80000007H: EBX[31] reserved
    }

    // ECX
    {
        if (vendor == .amd) amd_cpupwrsampletimeratio = cpuid_result.ecx;
    }

    // EDX
    {
        if (vendor == .amd) amd_ts = bitjuggle.isBitSet(cpuid_result.edx, 0);
        if (vendor == .amd) amd_fid = bitjuggle.isBitSet(cpuid_result.edx, 1);
        if (vendor == .amd) amd_vid = bitjuggle.isBitSet(cpuid_result.edx, 2);
        if (vendor == .amd) amd_ttp = bitjuggle.isBitSet(cpuid_result.edx, 3);
        if (vendor == .amd) amd_tm = bitjuggle.isBitSet(cpuid_result.edx, 4);
        // CPUID.80000001H: ECX[5] reserved
        if (vendor == .amd) amd_100mhzsteps = bitjuggle.isBitSet(cpuid_result.edx, 6);
        if (vendor == .amd) amd_hwpstate = bitjuggle.isBitSet(cpuid_result.edx, 7);
        invariant_tsc = bitjuggle.isBitSet(cpuid_result.edx, 8);
        if (vendor == .amd) amd_cpb = bitjuggle.isBitSet(cpuid_result.edx, 9);
        if (vendor == .amd) amd_efffreqro = bitjuggle.isBitSet(cpuid_result.edx, 10);
        if (vendor == .amd) amd_procfeedbackinterface = bitjuggle.isBitSet(cpuid_result.edx, 11);
        if (vendor == .amd) amd_procpowerreporting = bitjuggle.isBitSet(cpuid_result.edx, 12);
        // CPUID.80000001H: ECX[13] reserved
        // CPUID.80000001H: ECX[14] reserved
        // CPUID.80000001H: ECX[15] reserved
        // CPUID.80000001H: ECX[16] reserved
        // CPUID.80000001H: ECX[17] reserved
        // CPUID.80000001H: ECX[18] reserved
        // CPUID.80000001H: ECX[19] reserved
        // CPUID.80000001H: ECX[20] reserved
        // CPUID.80000001H: ECX[21] reserved
        // CPUID.80000001H: ECX[22] reserved
        // CPUID.80000001H: ECX[23] reserved
        // CPUID.80000001H: ECX[24] reserved
        // CPUID.80000001H: ECX[25] reserved
        // CPUID.80000001H: ECX[26] reserved
        // CPUID.80000001H: ECX[27] reserved
        // CPUID.80000001H: ECX[28] reserved
        // CPUID.80000001H: ECX[29] reserved
        // CPUID.80000001H: ECX[30] reserved
        // CPUID.80000001H: ECX[31] reserved
    }
}

/// Captures CPUID.80000008H.
fn capture80000008H() void {
    if (max_extended_leaf < 0x80000008) return;

    const cpuid_result = raw(0x80000008, 0);

    // EAX
    {
        physical_address_size = bitjuggle.getBits(cpuid_result.eax, 0, 8);
        linear_address_size = bitjuggle.getBits(cpuid_result.eax, 8, 8);
        guest_physical_address_size = bitjuggle.getBits(cpuid_result.eax, 16, 8);
        // CPUID.80000008H: EAX[24] reserved
        // CPUID.80000008H: EAX[25] reserved
        // CPUID.80000008H: EAX[26] reserved
        // CPUID.80000008H: EAX[27] reserved
        // CPUID.80000008H: EAX[28] reserved
        // CPUID.80000008H: EAX[29] reserved
        // CPUID.80000008H: EAX[30] reserved
        // CPUID.80000008H: EAX[31] reserved
    }

    // EBX
    {
        if (vendor == .amd) clzero = bitjuggle.isBitSet(cpuid_result.ebx, 0);
        if (vendor == .amd) instruction_retired_counter_msr = bitjuggle.isBitSet(cpuid_result.ebx, 1);
        if (vendor == .amd) fp_error_pointers_restored_by_xrstor = bitjuggle.isBitSet(cpuid_result.ebx, 2);
        if (vendor == .amd) invlpgb = bitjuggle.isBitSet(cpuid_result.ebx, 3);
        if (vendor == .amd) rdpru = bitjuggle.isBitSet(cpuid_result.ebx, 4);
        // CPUID.80000008H: EBX[5] reserved
        if (vendor == .amd) bandwidth_enforcement_extension = bitjuggle.isBitSet(cpuid_result.ebx, 6);
        // CPUID.80000008H: EBX[7] reserved
        if (vendor == .amd) mcommit = bitjuggle.isBitSet(cpuid_result.ebx, 8);
        wbnoinvd = bitjuggle.isBitSet(cpuid_result.ebx, 9);
        // CPUID.80000008H: EBX[10] reserved
        // CPUID.80000008H: EBX[11] reserved
        if (vendor == .amd) indirect_branch_prediction_barrier = bitjuggle.isBitSet(cpuid_result.ebx, 12);
        if (vendor == .amd) wbinvd_wbnoinvd_are_interruptible = bitjuggle.isBitSet(cpuid_result.ebx, 13);
        if (vendor == .amd) indirect_branch_restricted_speculation = bitjuggle.isBitSet(cpuid_result.ebx, 14);
        if (vendor == .amd) single_thread_indirect_branch_prediction_mode = bitjuggle.isBitSet(cpuid_result.ebx, 15);
        if (vendor == .amd) processor_prefers_that_ibrs_be_left_on = bitjuggle.isBitSet(cpuid_result.ebx, 16);
        if (vendor == .amd) processor_prefers_that_stibp_be_left_on = bitjuggle.isBitSet(cpuid_result.ebx, 17);
        if (vendor == .amd) ibrs_is_preferred_over_software = bitjuggle.isBitSet(cpuid_result.ebx, 18);
        if (vendor == .amd) ibrs_provides_same_mode_speculation_limits = bitjuggle.isBitSet(cpuid_result.ebx, 19);
        if (vendor == .amd) efer_lmsle_is_unsupported = bitjuggle.isBitSet(cpuid_result.ebx, 20);
        if (vendor == .amd) invlpgb_support_for_invalidating_guest_nested_translations = bitjuggle.isBitSet(cpuid_result.ebx, 21);
        // CPUID.80000008H: EBX[22] reserved
        // CPUID.80000008H: EBX[23] reserved
        if (vendor == .amd) speculative_store_bypass_disable = bitjuggle.isBitSet(cpuid_result.ebx, 24);
        if (vendor == .amd) use_virt_spec_ctl_for_ssbd = bitjuggle.isBitSet(cpuid_result.ebx, 25);
        if (vendor == .amd) ssbd_not_needed = bitjuggle.isBitSet(cpuid_result.ebx, 26);
        if (vendor == .amd) collaborative_processor_performance_control = bitjuggle.isBitSet(cpuid_result.ebx, 27);
        if (vendor == .amd) predictive_store_forward_disable = bitjuggle.isBitSet(cpuid_result.ebx, 28);
        if (vendor == .amd) processor_is_not_affected_by_branch_type_confusion = bitjuggle.isBitSet(cpuid_result.ebx, 29);
        if (vendor == .amd) return_address_predictor_cleared_on_ibpb_write = bitjuggle.isBitSet(cpuid_result.ebx, 30);
        // CPUID.80000008H: EBX[31] reserved
    }

    // ECX
    {
        if (vendor == .amd) physical_threads = bitjuggle.getBits(cpuid_result.ecx, 0, 8);
        // CPUID.80000008H: ECX[8] reserved
        // CPUID.80000008H: ECX[9] reserved
        // CPUID.80000008H: ECX[10] reserved
        // CPUID.80000008H: ECX[11] reserved
        if (vendor == .amd) apic_id_size = bitjuggle.getBits(cpuid_result.ecx, 12, 4);
        if (vendor == .amd) performance_time_stamp_counter_size = @enumFromInt(bitjuggle.getBits(cpuid_result.ecx, 16, 2));
        // CPUID.80000008H: ECX[18] reserved
        // CPUID.80000008H: ECX[19] reserved
        // CPUID.80000008H: ECX[20] reserved
        // CPUID.80000008H: ECX[21] reserved
        // CPUID.80000008H: ECX[22] reserved
        // CPUID.80000008H: ECX[23] reserved
        // CPUID.80000008H: ECX[24] reserved
        // CPUID.80000008H: ECX[25] reserved
        // CPUID.80000008H: ECX[26] reserved
        // CPUID.80000008H: ECX[27] reserved
        // CPUID.80000008H: ECX[28] reserved
        // CPUID.80000008H: ECX[29] reserved
        // CPUID.80000008H: ECX[30] reserved
        // CPUID.80000008H: ECX[31] reserved
    }

    // EDX
    {
        if (vendor == .amd) maximum_page_count_for_invlpgb = bitjuggle.getBits(cpuid_result.edx, 0, 16);
        if (vendor == .amd) maximum_ecx_value_for_rdpru = bitjuggle.getBits(cpuid_result.edx, 16, 16);
    }
}

pub const Leaf = struct {
    eax: u32,
    ebx: u32,
    ecx: u32,
    edx: u32,
};

pub fn raw(leaf_id: u32, subid: u32) Leaf {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [_] "={eax}" (eax),
          [_] "={ebx}" (ebx),
          [_] "={ecx}" (ecx),
          [_] "={edx}" (edx),
        : [_] "{eax}" (leaf_id),
          [_] "{ecx}" (subid),
    );
    return .{ .eax = eax, .ebx = ebx, .ecx = ecx, .edx = edx };
}

pub const ProcessorType = enum(u2) {
    /// Original OEM Processor
    original_oem = 0b00,
    /// Intel OverDrive Processor
    overdrive = 0b01,
    /// Dual processor (not applicable to Intel486 processors)
    dual_processor = 0b10,
    /// Intel reserved
    reserved = 0b11,
};

// TODO: CPUID.02H - TLB/Cache/Prefetch Information (Intel Only)
// TODO: CPUID.03H - Processor Serial Number (Intel Only)
// TODO: CPUID.04H - Deterministic Cache Parameters (Intel Only)
// TODO: CPUID.05H - MONITOR/MWAIT
// TODO: CPUID.09H - Direct Cache Access Information (Intel Only)
// TODO: CPUID.0AH - Architectural Performance Monitoring (Intel Only)
// TODO: CPUID.0BH - Extended Topology Enumeration
// TODO: CPUID.0DH - Processor Extended State Enumeration
// TODO: CPUID.0FH - Intel Resource Director Technology Monitoring Enumeration Information (Intel Only)
// TODO: CPUID.0FH - PQOS Monitoring (AMD Only)
// TODO: CPUID.10H - Intel Resource Director Technology Allocation Enumeration Information (Intel Only)
// TODO: CPUID.10H - PQOS Enforcement (AMD Only)
// TODO: CPUID.12H - Intel SGX Enumeration Information (Intel Only)
// TODO: CPUID.14H - Intel Processor Trace Enumeration Information (Intel Only)
// TODO: CPUID.17H - System-On-Chip Information (Intel Only)
// TODO: CPUID.18H - Deterministic Address Translation Parameters (Intel Only)
// TODO: CPUID.19H - Key Locker (Intel Only)
// TODO: CPUID.1AH - Native Model ID Enumeration (Intel Only)
// TODO: CPUID.1BH - PCONFIG Information Sub-leaf (Intel Only)
// TODO: CPUID.1CH - Last Branch Records Information (Intel Only)
// TODO: CPUID.1DH - Tile Information (Intel Only)
// TODO: CPUID.1EH - TMUL Information (Intel Only)
// TODO: CPUID.1FH - V2 Extended Topology Enumeration (Intel Only)
// TODO: CPUID.20H - History Reset Information (Intel Only)
// TODO: CPUID.80000005H - L1 Cache and TLB Information (AMD Only)
// TODO: CPUID.80000006H - L2 Cache and TLB and L3 Cache Information (AMD Only)
// TODO: CPUID.80000006H - Cache stuff (Intel Only)
// TODO: CPUID.80000008H - Processor Capacity Parameters and Extended Feature Identification (AMD Only)
// TODO: CPUID.8000000AH - SVM Features (AMD Only)
// TODO: CPUID.80000019H - TLB Characteristics for 1GB pages (AMD Only)
// TODO: CPUID.8000001AH - Instruction Optimizations (AMD Only)
// TODO: CPUID.8000001BH - Instruction-Based Sampling Capabilities (AMD Only)
// TODO: CPUID.8000001CH - Lightweight Profiling Capabilities (AMD Only)
// TODO: CPUID.8000001DH - Cache Topology Information (AMD Only)
// TODO: CPUID.8000001EH - Processor Topology Information (AMD Only)
// TODO: CPUID.8000001FH - Encrypted Memory Capabilities (AMD Only)
// TODO: CPUID.80000020H - PQOS Extended Features (AMD Only)
// TODO: CPUID.80000021H - Extended Feature Identification 2 (AMD Only)
// TODO: CPUID.80000022H - Extended Performance Monitoring and Debug (AMD Only)
// TODO: CPUID.80000023H - Multi-Key Encrypted Memory Capabilities (AMD Only)
// TODO: CPUID.80000026H - Extended CPU Topology (AMD Only)
// TODO: Processor Brand String's - Search "The Processor Brand String Method" in the Intel manual.
