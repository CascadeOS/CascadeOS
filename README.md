# CascadeOS

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

## Discord Server
This project has a [Discord server](https://discord.gg/3hnsQmND3c).

## Contributing
Issues with the label "contributor friendly" would be a good place to start after having a look around the code base.

If you have any experience with aarch64 or risc-v then assitance with those architectures would be greatly appreciated.
