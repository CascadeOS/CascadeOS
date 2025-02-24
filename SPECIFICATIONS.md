# Specifications
This is intended to be a listing of all the specifications (and other useful documents) used during the construction of CascadeOS.

It is possible for these links or the text regarding versions to become out of date, any problems found don't hesitate to open a PR or raise an issue.

---

* ARM - [Arm Architecture Reference Manual for A-profile architecture](https://developer.arm.com/documentation/ddi0487/ja/?lang=en)
* ACPI/UEFI/GPT
  * [Specifications](https://uefi.org/specifications) (GPT is specified in the UEFI spec) 
  * [Microsoft Debug Port Table 2 (DBG2)](https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/bringup/acpi-debug-port-table.md)
  * [Serial Port Console Redirection Table](https://github.com/MicrosoftDocs/windows-driver-docs/blob/staging/windows-driver-docs-pr/serports/serial-port-console-redirection-table.md)
* Devices
  * [ARM PL011](https://developer.arm.com/documentation/ddi0183/latest/)
  * [HPET](http://www.intel.com/content/dam/www/public/us/en/documents/technical-specifications/software-developers-hpet-spec-1-0a.pdf)
  * [I/O APIC](http://web.archive.org/web/20161130153145/http://download.intel.com/design/chipsets/datashts/29056601.pdf)
  * 16550
    * [UART 16550](https://caro.su/msx/ocm_de1/16550.pdf)
    * [PC16550D Universal Asynchronous Receiver/Transmitter with FIFOs](https://media.digikey.com/pdf/Data%20Sheets/Texas%20Instruments%20PDFs/PC16550D.pdf)
* Device Tree
  * [Specification](https://github.com/devicetree-org/devicetree-specification)
  * [Bindings](https://www.kernel.org/doc/Documentation/devicetree/bindings/)
  * [Device Tree Reference](https://elinux.org/Device_Tree_Reference)
  * [Device Tree Usage](https://elinux.org/Device_Tree_Usage)
* Ext
  * [ext2-doc](https://www.nongnu.org/ext2-doc/)
  * [Linux Ext4 documentation](https://www.kernel.org/doc/html/latest/filesystems/ext4/index.html)
  * [Ext4 wiki](https://ext4.wiki.kernel.org/index.php/Main_Page)
  * https://ext4.wiki.kernel.org/index.php/Ext4_Disk_Layout
* FAT32
  * Microsoft Spec: [FAT: General Overview of On-Disk Format](https://www.win.tue.nl/~aeb/linux/fs/fat/fatgen103.pdf)
  * [Understanding FAT32](https://www.pjrc.com/tech/8051/ide/fat32.html)
  * [Design of the FAT file system](https://en.wikipedia.org/wiki/Design_of_the_FAT_file_system)
  * [FAT Filesystem](http://elm-chan.org/docs/fat_e.html)
* Limine - [Limine Boot Protocol](https://github.com/limine-bootloader/limine/blob/stable/PROTOCOL.md)
* RISC-V - [Unprivileged and Privileged ISA](https://github.com/riscv/riscv-isa-manual)
* SDF - [SDF Spec](lib/sdf/sdf.md)
* PCI
  * [PCI Express® Base Specification Revision 5.0 Version 1.0 22 May 2019](https://picture.iczhiku.com/resource/eetop/SYkDTqhOLhpUTnMx.pdf)
  * PCI Code and ID Assignment Specification Revision 1.14 17 Nov 2021
* System-V/ELF
  * [Generic ABI (gABI)](https://www.sco.com/developers/devspecs/) latest at time of writing: Edition 4.1
  * [Generic ABI (gABI) updates](https://www.sco.com/developers/gabi/) updates to chapter 4 and 5 of the above. Latest at time of writing: DRAFT 10 June 2013 (under the "Latest (in progress) snapshot" link)
  * [ARM psABI](https://github.com/ARM-software/abi-aa)
  * [RISC-V psABI](https://github.com/riscv-non-isa/riscv-elf-psabi-doc)
  * [x64 psABI](https://gitlab.com/x86-psABIs/x86-64-ABI)
* UUID - [RFC 9562](https://www.rfc-editor.org/rfc/rfc9562.html)
* VirtIO - [VirtIO Specs](https://docs.oasis-open.org/virtio/virtio/)
* x64
  * [AMD](https://www.amd.com/en/search/documentation/hub.html#q=AMD64%20Architecture%20Programmer's%20Manual&f-amd_document_type=Programmer%20References) link is to a search as AMD don't provide an always up to date link to the documents
  * [Intel](https://www.intel.com/content/www/us/en/developer/articles/technical/intel-sdm.html)

