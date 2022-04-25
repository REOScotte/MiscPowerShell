# Location that contains junction.exe from the Sysinternals tools.
$sysinternalsPath = 'C:\SysinternalsSuite'

# Your profile folder
$userProfile = $env:USERPROFILE
$redirectedFolder = "$userProfile\Documents\RedirectedBackupFiles"

# Original locations - this may vary depending if VSCode is installed machine-wide.
$nppBackup     = "$userProfile\AppData\Roaming\Notepad++\backup"
$vsCodeBackups = "$userProfile\AppData\Roaming\Code\Backups"
$ise3000       = "$userProfile\AppData\Local\Microsoft_Corporation\PowerShell_ISE.exe_StrongName_lw2v2vm3wmtzzpebq33gybmeoxukb04w\3.0.0.0"

# The destinations should be in a location that's backed up.
$nppDestination    = "$redirectedFolder\NPP"
$vsCodeDestination = "$redirectedFolder\VSCode"
$iseDestination    = "$redirectedFolder\ISE"

# Created the folder to store the redirected files.
$null = New-Item -Path $redirectedFolder -ItemType Directory -Force

# Move the existing Notepad++ backup folder.
Move-Item -Path $nppBackup -Destination $nppDestination -Force

# Move the existing VSCode Backups folder.
Move-Item -Path $vsCodeBackups -Destination $vsCodeDestination -Force

# Move the existing ISE 3.0.0.0 folder.
Move-Item -Path $ise3000 -Destination $iseDestination -Force

# Create a junction point to the new Notepad++ location
Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @($nppBackup, $nppDestination)

# Create a junction point to the new VSCode location
Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @($vsCodeBackups, $vsCodeDestination)

# Create a junction point to the new ISE location
Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @($ise3000, $iseDestination)

<# Stop redirecting Notepad++
    Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @('/d',$nppBackup)
    New-Item -Path $vsCodeBackups -ItemType Directory
#>

<# Stop redirecting VSCode
    Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @('/d',$vsCodeBackups)
    New-Item -Path $vsCodeBackups -ItemType Directory
#>

<# Stop redirecting ISE
    Start-Process -Wait -FilePath "$sysinternalsPath\junction.exe" -ArgumentList @('/d',$ise3000)
    New-Item -Path $ise3000 -ItemType Directory
#>