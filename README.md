# CascadeOS

[![justforfunnoreally.dev badge](https://img.shields.io/badge/justforfunnoreally-dev-9ff)](https://justforfunnoreally.dev)

Cascade is a general purpose operating system targeting standard desktops and laptops.

## Short Term Goals
- Good enough x86-64 support for QEMU (virtio drivers)
- Userspace, no GUI
- ext2 on NVMe

## Planned Features
- x86_64, AArch64/UEFI and RISC-V/UEFI
- First class Zig support
- Linux compatibility mode (allowing static linux binaries to run unchanged)
- Userspace with GUI
- All functionality implemented in Zig either in repo or as a package, allowances might be made for things like [ACPICA](https://acpica.org/).

## Build, testing, running
### Prerequisites:
- zig master
- git (optional; used for fetching the limine bootloader when building a disk image)
- qemu (optional; used for running and host testing)

Run the x86_64 kernel in QEMU:
```sh
zig build run_x86_64
```

List all available build targets:
```sh
zig build -l
```

Run all tests and build all code: 
```sh
zig build --summary all
```

Run `zig build -h` for a listing of the available steps and options.

## Contributing
Issues with the label "contributor friendly" would be a good place to start after having a look around the code base.

If you have any experience with AArch64 or RISC-V then assitance with those architectures would be greatly appreciated.

## Discord Server
This project has a [Discord server](https://discord.gg/3hnsQmND3c).
