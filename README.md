# CircuitOS

Circuit is a general purpose operating system targeting standard desktops and laptops.

## Short Term Goals
- Good enough x86-64 support for QEMU
- Userspace, no gui
- ext2 on NVMe

## Planned Features
- x86_64, AArch64/UEFI and RISC-V/UEFI
- First class Zig support
- Linux syscall compatibility mode (allowing static linux binaries to run unchanged)
- Userspace with GUI (probably using Wayland meaning along with the feature above static linux binaries should work out of the box)
- All functionality implemented in Zig either in repo or as a package, allowances might be made for things like [ACPICA](https://acpica.org/).

## Discord Server
This project has a [Discord server](https://discord.gg/GZMm2FS3).

## Contributing
There are a few ways to contribute to the project at the stage it is at:
- Just try to boot the thing and report the many issues you will hit 💩
- Search the code for 'TODO' (these should probably be made into issues)

TODO: Add better contributing steps, including build instructions
