# CascadeOS

[![justforfunnoreally.dev badge](https://img.shields.io/badge/justforfunnoreally-dev-9ff)](https://justforfunnoreally.dev)

Cascade is a general purpose operating system targeting standard desktops and laptops.

## Short Term Goals
- Good enough x64 support for QEMU (virtio drivers)
- Userspace, no GUI
- ext2 on NVMe

## Planned Features
- x64, ARM64 and RISC-V
- First class Zig support
- Userspace with GUI
- All functionality implemented in Zig either in repo or as a package, allowances might be made for things like [ACPICA](https://acpica.org/).

## Build, testing, running
### Prerequisites:
- zig master (0.14.0-dev.1409+6d2945f1f)
- qemu (optional; used for running and host testing)

Run the x64 kernel in QEMU:
```sh
zig build run_x64
```

List all available build targets:
```sh
zig build -l
```

Run all tests and build all code: 
```sh
zig build test --summary all
```

Run `zig build -h` for a listing of the available steps and options.

## License
This project follows the [REUSE Specification](https://reuse.software/spec/) for specifying license information.
