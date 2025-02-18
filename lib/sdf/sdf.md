# Simple Debug Format (SDF) Version 1

A simple debug format that provides:
 - File, symbol, line and column from instruction address.
 - Unwind information (PLANNED)

Does not support relocatable addresses.

## Versioning

SDF is a backwards compatible format, new versions will only add new functionality.

This means valid usage can be assured by checking if the header field `version` is _less than or equal_ to the version you require for the functionality you need.

In any future versions of this specification added fields or data structures will be clearly marked with the version they are available from.

## Header

The entry point to SDF that provides access to each of the specific data structures.

Due to the offsets contained in this header being unsigned the header must proceed all other data structures in memory.

| offset | name | type | description |
|:-|:-|:-:|:-|
|0|`identifier`|`[8]u8`|Magic bytes to identify the data as SDF. Must equal "SDFSDFSD".
|8|`version`|`u8`|Version of the SDF format. This document specifies version `1`.
|9|_reserved_|`[7]u8`|
|16|`total_size_of_sdf_data`|`leu64`|The total size of the SDF data in bytes from the start of the header.
|24|`string_table_offset`|`leu64`|The byte offset from the start of the header to the string table.
|32|`string_table_length`|`leu64`|The length of the string table in bytes.
|40|`file_table_offset`|`leu64`|The byte offset from the start of the header to the file table.
|48|`file_table_entries`|`leu64`|The number of entries in the file table.
|56|`location_lookup_offset`|`leu64`|The byte offset from the start of the header to the location lookup.
|64|`location_program_states_offset`|`leu64`|The byte offset from the start of the header to the location program states.
|72|`location_lookup_entries`|`leu64`|The number of entries in the location lookup and location program states.
|80|`location_program_offset`|`leu64`|The byte offset from the start of the header to the location program.
|88|`location_program_length`|`leu64`|The length of the location program in bytes.

## String Table

A table containing all strings referenced by the SDF data as null-terminated UTF-8 strings.

Strings are referenced by offset from the start of the string table.

## File Table

An array of `FileEntry` structures containing information about each file referenced by the SDF data.

Files are referenced by index.

#### File Entry (`FileEntry`)
| offset | name | type | description |
|:-|:-|:-:|:-|
|0|`directory_offset`|`leu64`|Offset of the directory name in the string table.
|8|`file_offset`|`leu64`|Offset of the file name in the string table.

## Location Lookup

An array of instruction addresses (`leu64`) sorted in ascending order.

The index of the address corresponds to the index within the location program states for the state for that address,
this serves as an efficient starting point for the location program closer to the target address.

## Location Program States

An array of `LocationProgramState` structures.

States are referenced by index.

#### Location Program State (`LocationProgramState`)
| offset | name | type | description |
|:-|:-|:-:|:-|
|0|`instruction_offset`|`leu64`|The byte offset into the location program of the instruction to execute.
|8|`address`|`leu64`|The address register associated with this state.
|16|`file_index`|`leu64`|The file index register associated with this state.
|24|`symbol_offset`|`leu64`|The symbol offset register associated with this state.
|32|`line`|`leu64`|The line register associated with this state.
|40|`column`|`leu64`|The column register associated with this state.

## Location Program

A bytecode program that determines the file, symbol, line and column for an address.

The location program can be run from its beginning up to the target address. However, as an address could be a long
way into the program, the location lookup and location program states can be used to "jump" into the location program
closer to the target address.

#### Location Program Registers
| name | type | initial value |
|:-|:-:|:-:|
|address|`u64`|`0`
|file_index|`u64`|`maxInt(u64)`
|symbol_offset|`u64`|`maxInt(u64)`
|line|`u64`|`0`
|column|`u64`|`0`

### Location Program Instructions

Each instruction is represented as a one-byte opcode followed by zero or more operands as specified by the opcode.
| name | opcode | description |
|:-|:-:|:-|
|offset address|`0x1`|Add the subsequent ULEB128 encoded number to the `address` register.
|increment address by two|`0x2`|Increment the `address` register by two.
|increment address by three|`0x3`|Increment the `address` register by three.
|increment address by four|`0x4`|Increment the `address` register by four.
|increment address by five|`0x5`|Increment the `address` register by five.
|increment address by six|`0x6`|Increment the `address` register by six.
|increment address by seven|`0x7`|Increment the `address` register by seven.
|increment address by eight|`0x8`|Increment the `address` register by eight.
|increment address by nine|`0x9`|Increment the `address` register by nine.
|increment address by ten|`0xA`|Increment the `address` register by ten.
|increment address by eleven|`0xB`|Increment the `address` register by eleven.
|increment address by twelve|`0xC`|Increment the `address` register by twelve.
|increment address by thirteen|`0xD`|Increment the `address` register by thirteen.
|increment address by fourteen|`0xE`|Increment the `address` register by fourteen.
|increment address by fifteen|`0xF`|Increment the `address` register by fifteen.
|increment address by sixteen|`0x10`|Increment the `address` register by sixteen.
|increment address by seventeen|`0x11`|Increment the `address` register by seventeen.
|increment address by eighteen|`0x12`|Increment the `address` register by eighteen.
|increment address by nineteen|`0x13`|Increment the `address` register by nineteen.
|increment address by twenty|`0x14`|Increment the `address` register by twenty.
|increment address by twenty one|`0x15`|Increment the `address` register by twenty one.
|increment address by twenty two|`0x16`|Increment the `address` register by twenty two.
|increment address by twenty three|`0x17`|Increment the `address` register by twenty three.
|increment address by twenty four|`0x18`|Increment the `address` register by twenty four.
|increment address by twenty five|`0x19`|Increment the `address` register by twenty five.
|increment address by twenty six|`0x1A`|Increment the `address` register by twenty six.
|increment address by twenty seven|`0x1B`|Increment the `address` register by twenty seven.
|increment address by twenty eight|`0x1C`|Increment the `address` register by twenty eight.
|increment address by twenty nine|`0x1D`|Increment the `address` register by twenty nine.
|increment address by thirty|`0x1E`|Increment the `address` register by thirty.
|increment address by thirty one|`0x1F`|Increment the `address` register by thirty one.
|increment address by thirty two|`0x20`|Increment the `address` register by thirty two.
|set symbol offset|`0x21`|Set the `symbol_offset` register to the subsequent ULEB128 encoded number.
|set file index|`0x22`|Set the `file_index` register to the subsequent ULEB128 encoded number.
|offset column|`0x23`|Add the subsequent SLEB128 encoded number to the `column` register using a wrapping operation.
|offset line|`0x24`|Add the subsequent SLEB128 encoded number to the `line` register using a wrapping operation.
|increment line by one|`0x25`|Increment the `line` register by one.
|increment line by two|`0x26`|Increment the `line` register by two.
|increment line by three|`0x27`|Increment the `line` register by three.
|increment line by four|`0x28`|Increment the `line` register by four.
|increment line by five|`0x29`|Increment the `line` register by five.
|increment line by six|`0x2A`|Increment the `line` register by six.
|increment line by seven|`0x2B`|Increment the `line` register by seven.
|increment line by eight|`0x2C`|Increment the `line` register by eight.
|increment line by nine|`0x2D`|Increment the `line` register by nine.
|increment line by ten|`0x2E`|Increment the `line` register by ten.
|increment line by eleven|`0x2F`|Increment the `line` register by eleven.
|increment line by twelve|`0x30`|Increment the `line` register by twelve.
|decrement line by one|`0x31`|Decrement the `line` register by one.
|decrement line by two|`0x32`|Decrement the `line` register by two.
|decrement line by three|`0x33`|Decrement the `line` register by three.
|decrement line by four|`0x34`|Decrement the `line` register by four.
|decrement line by five|`0x35`|Decrement the `line` register by five.
|decrement line by six|`0x36`|Decrement the `line` register by six.
|decrement line by seven|`0x37`|Decrement the `line` register by seven.
|decrement line by eight|`0x38`|Decrement the `line` register by eight.
|decrement line by nine|`0x39`|Decrement the `line` register by nine.
|decrement line by ten|`0x3A`|Decrement the `line` register by ten.
|decrement line by eleven|`0x3B`|Decrement the `line` register by eleven.
|decrement line by twelve|`0x3C`|Decrement the `line` register by twelve.

## Procedure

Assuming the header has been found and successfully parsed the procedure to acquire the file, symbol, line and column for a target address is:
1. Search the location lookup table for the largest address that is _less than or equal_ to the target address.
2. Read the `LocationProgramState` from the location program states at the index found in step 1.
3. Set the register `address` to the `address` field of the `LocationProgramState` read in step 2.
4. Set the register `file_index` to the `initial_file_index` field of the `LocationProgramState` read in step 2.
5. Set the register `symbol_offset` to the `initial_symbol_offset` field of the `LocationProgramState` read in step 2.
6. Set the register `line` to the `initial_line` field of the `LocationProgramState` read in step 2.
7. Set the register `column` to the `initial_column` field of the `LocationProgramState` read in step 2.
8. Seek in the location program to the offset `instruction_offset` as given by the `LocationProgramState` read in step 2.
9. While the location program register `address` is _less than or equal_ to the target address read the opcode and perform the specified operation.

If the end of the location program is encountered and the `address` register is _less than_ to the target address, then the target address has no location information encoded and the contents of the registers must be ignored.

The values of the location program registers at termination of the loop in step 9 are the result of the location program for the target address.

If the `address`, `line` or `column` registers are `0` that register is invalid/not set. If the `file_index` or `symbol_offset` registers are `maxInt(u64)` that value is invalid/not set.