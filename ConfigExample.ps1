Import-Module C:\Users\CJ\Documents\Programming\powershell\processcoach\ProcessCoach.psm1 -Force

$note1Job = New-ProcessCoach-Prog -Label "Notepad1" -FilePath "notepad.exe" -WaitAfterLaunch 2 -Foreground -OnExit {
    param($process)
    $exitCode = $process.ExitCode
    Write-Host "Notepad Exited. Exit code: $exitCode"
    return $false
}
$note2Job = New-ProcessCoach-Prog -Label "Notepad2" -FilePath "notepad.exe" -Dependency "Notepad1"

Start-ProcessCoach -Progs $note1Job, $note2Job
