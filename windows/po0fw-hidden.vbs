' po0fw silent launcher
' Starting powershell.exe directly can briefly create a conhost window before
' -WindowStyle Hidden takes effect. wscript.exe has no console, so use it to
' launch the PowerShell worker without a visible window.
Option Explicit

Dim shell, fso, scriptDir, ps1, args, arg, i, cmd

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptDir = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = fso.BuildPath(scriptDir, "po0fw.ps1")

' Forward script arguments such as -Status or -Tokens "pgnfw_a,pgnfw_b".
args = ""
For i = 0 To WScript.Arguments.Count - 1
    arg = WScript.Arguments(i)
    If InStr(arg, " ") > 0 Or InStr(arg, ",") > 0 Or InStr(arg, ";") > 0 Then
        args = args & " """ & Replace(arg, """", "\""") & """"
    Else
        args = args & " " & arg
    End If
Next

cmd = "powershell.exe -NoProfile -NonInteractive -WindowStyle Hidden " & _
      "-ExecutionPolicy Bypass -File """ & ps1 & """" & args

' 0 = hidden window; False = do not wait for completion.
shell.Run cmd, 0, False
