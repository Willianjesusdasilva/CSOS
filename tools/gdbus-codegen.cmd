@echo off
set "UNINSTALLED_GLIB_SRCDIR="
"%LOCALAPPDATA%\Programs\Python\Python313\python.exe" "%~dp0..\zig-out\glib-host2\gio\gdbus-2.0\codegen\gdbus-codegen" %*
