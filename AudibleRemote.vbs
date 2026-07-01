' Launches Audible Remote with no console window flashing.
' Double-click this file to run. (wscript.exe is Microsoft-signed, so Smart App
' Control allows it; it just starts Windows PowerShell on the .ps1 next to it.)
Dim shell, here
Set shell = CreateObject("WScript.Shell")
here = Left(WScript.ScriptFullName, InStrRev(WScript.ScriptFullName, "\"))
shell.Run "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File """ & here & "AudibleRemote.ps1""", 0, False
