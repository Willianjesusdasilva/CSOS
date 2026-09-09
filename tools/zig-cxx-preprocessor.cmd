@echo off
rem WebKit's Perl binding generator appends -E/-P/-x c++ to this command.
rem Keep the Zig driver subcommand explicit; passing `zig.exe -E` is invalid.
"%~dp0..\.tools\zig-x86_64-windows-0.16.0\zig.exe" c++ -E %*
