Add-Type @"
  using System;
  using System.Threading;
  using System.Runtime.InteropServices;
  namespace LocalProjects.ProcessCoach {
      public class Helpers {
         [DllImport("user32.dll")]
         [return: MarshalAs(UnmanagedType.Bool)]
         public static extern bool SetForegroundWindow(IntPtr hWnd);
      }
  }
"@

<#
.Synopsis
   Create a new process coach program definition
#>
function New-ProcessCoach-Prog
{
    [CmdletBinding()]
    [OutputType([PSObject])]
    Param
    (
        # Identifying label for this project (to be used for dependencies)
        [Parameter(Mandatory=$true,
                   Position=0)]
        [string]
        $Label,

        # Path to execute
        [Parameter(Mandatory=$true,
                   Position=1)]
        [string]
        $FilePath,

        # List of arguments to pass to program
        [string[]]
        $ArgumentList,

        # For now we only allow one dependency so we don't need to worry
        # about writing a complicated dependency graph resolver
        # (which may be fun in the future but I don't have time right now)
        [string]
        $Dependency,

        # Set the working directory for program
        [string]
        $WorkingDir,

        # Seconds to wait after launching program
        # before launching any following programs
        [Int]
        $WaitAfterLaunch=0,

        # Should this program be brought to the foreground
        # (can only be defined on one program definition)
        [switch]
        $Foreground,

        # Script that gets called when the program exits. Return false to
        # have the program restart, $true to leave the program down. 
        [ScriptBlock]
        $OnExit={param($process) return $false}
    )

    $prog = New-Object PSObject
    $prog | Add-Member NoteProperty -Name Label -Value $Label
    $prog | Add-Member NoteProperty -Name FilePath -Value $FilePath
    $prog | Add-Member NoteProperty -Name ArgumentList -Value $ArgumentList
    $prog | Add-Member NoteProperty -Name Dependency -Value $Dependency
    $prog | Add-Member NoteProperty -Name WorkingDir -Value $WorkingDir
    $prog | Add-Member NoteProperty -Name WaitAfterLaunch -Value $WaitAfterLaunch
    $prog | Add-Member NoteProperty -Name Foreground -Value $Foreground
    $prog | Add-Member NoteProperty -Name OnExit -Value $OnExit

    $prog | Add-Member NoteProperty -Name Process -Value $null
    $prog | Add-Member NoteProperty -Name Dependents -Value @()
    return $prog
}

<#
.Synopsis
   Start process coach for keeping track of program definitions
#>
function Start-ProcessCoach
{
    [CmdletBinding()]
    Param
    (
        # Program definitions to keep track of
        [Parameter(Mandatory=$true,
                   Position=0)]
        [PSObject[]]
        $Progs,

        # Title to change the window title to for easier identification
        [string]
        $WindowTitle="ProcessCoach"
    )

    $lookup = @{}
    $entry = @()
    $foreground_prog = $null

    foreach ($prog in $Progs) {

        if ($prog.Foreground) {
            if ($foreground_prog) {
                throw "Multiple foreground programs specified."
            }

            $foreground_prog = $prog
        }

        if ($lookup.Contains($prog.Label)) {
            throw "Label used multiple times."
        }

        $lookup.Add($prog.Label, $prog)
    }

    foreach ($prog in $Progs) {

        if ($prog.Dependency) {
            $dep = $lookup.Get_Item($prog.Dependency)
            $dep.Dependents += $prog
        } else {
            $entry += $prog
        }
    }

    if (-not ($entry)) {
        throw "No entry point found. Most likely means there are circular dependencies"
    }

    $host.ui.RawUI.WindowTitle = $WindowTitle

    $processes = New-Object System.Collections.ArrayList

    function Stop-ProcessCoach-Prog {
        [CmdletBinding()]
        Param
        (
            # Program to stop
            [Parameter(Mandatory=$true,
                        Position=0)]
            [PSObject]
            $Prog
        )

        if ($Prog.Process -and -not $prog.Process.HasExited) {
            $processes.Remove($Prog.Process)
            $Prog.Process | Stop-Process -Force
        }
    }

    function Start-ProcessCoach-Prog {
        [CmdletBinding()]
        Param
        (
            # Program to start
            [Parameter(Mandatory=$true,
                        Position=0)]
            [PSObject]
            $Prog
        )
        foreach ($dep in $Prog.Dependents) {
            Stop-ProcessCoach-Prog -Prog $dep
        }
        $progArgs = @{
            FilePath = $Prog.FilePath
        }

        if ($Prog.ArgumentList) {
            $progArgs.Add("ArgumentList", $Prog.ArgumentList)
        }

        if ($Prog.WorkingDir) {
            $progArgs.Add("WorkingDirectory", $Prog.WorkingDir)
        }
        $process = Start-Process @progArgs -PassThru

        $process | Add-Member NoteProperty -Name ProcessCoachProg -Value $Prog

        $Prog.Process = $process

        Start-Sleep -s $prog.WaitAfterLaunch
        $processes.Add($process)

        foreach ($dep in $Prog.Dependents) {
            Start-ProcessCoach-Prog -Prog $dep
        }
            
        return $process
    }

    foreach ($prog in $entry) {
        Start-ProcessCoach-Prog -Prog $prog | Out-Null
    }

    # We need to give the windows a second or so to initialize before changing the foreground or else they may
    # popup over the forground when they do initialize. I really want to find a programatic way of finding out the
    # state of a WindowHandle and using that rather than arbitrarily waiting.
    Start-Sleep -m 500
    if (-not ($foreground_prog.process.HasExited)) {
        [LocalProjects.ProcessCoach.Helpers]::SetForegroundWindow($foreground_prog.process.MainWindowHandle) | Out-Null
    }



    while ($processes) {        
        $handlers = @()
        foreach ($proc in $processes) {
                $safeHandle = New-Object Microsoft.Win32.SafeHandles.SafeWaitHandle -ArgumentList $proc.Handle, $false
                $manual = New-Object System.Threading.ManualResetEvent $true
                $manual.SafeWaitHandle = $safeHandle
                $handlers += $manual
        }
        $index = [System.Threading.WaitHandle]::WaitAny($handlers)
        $proc = $processes[$index]
        $processes.RemoveAt($index)
        if (-not (&$proc.ProcessCoachProg.OnExit -process $proc)) {
            Start-ProcessCoach-Prog -Prog $proc.ProcessCoachProg | Out-Null
        }

        Start-Sleep -m 500
        if (-not ($foreground_prog.process.HasExited)) {
            [LocalProjects.ProcessCoach.Helpers]::SetForegroundWindow($foreground_prog.process.MainWindowHandle) | Out-Null
        }
    
    }
}
