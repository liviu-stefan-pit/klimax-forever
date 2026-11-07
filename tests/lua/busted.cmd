@echo off
rem Runs busted for the Klimax Lua specs on this machine.
rem Lua 5.1 comes from Scoop (lua-for-windows). busted and its pure-Lua deps are in
rem %USERPROFILE%\.luarocks. lfs.dll comes from Lua for Windows' clibs. term.lua and
rem system.lua are local shims in .luarocks\share (lua-term and luasystem can't be built here).
set "LFW=%USERPROFILE%\scoop\apps\lua-for-windows\current"
set "LUA_PATH=%LFW%\lua\?.lua;%LFW%\lua\?\init.lua;%USERPROFILE%\.luarocks\share\lua\5.1\?.lua;%USERPROFILE%\.luarocks\share\lua\5.1\?\init.lua;;"
set "LUA_CPATH=%LFW%\clibs\?.dll;;"
"%USERPROFILE%\.luarocks\bin\busted.bat" %*
