# Your profile folder
$userProfile = $env:USERPROFILE
$redirectedFolder = "$userProfile\OneDrive\Backup"

# Original locations - this may vary depending if VSCode is installed machine-wide.
$nppBackup     = "$userProfile\AppData\Roaming\Notepad++\backup"
$vsCodeBackups = "$userProfile\AppData\Roaming\Code\Backups"
$ise3000       = "$userProfile\AppData\Local\Microsoft_Corporation\PowerShell_ISE.exe_StrongName_lw2v2vm3wmtzzpebq33gybmeoxukb04w\3.0.0.0"

# The destinations should be in a location that's backed up.
$nppDestination    = "$redirectedFolder\NPP"
$vsCodeDestination = "$redirectedFolder\VSCode"
$iseDestination    = "$redirectedFolder\ISE"

# Create a junction point to the new Notepad++ location
cmd /c mklink /j $nppBackup $nppDestination

# Create a junction point to the new VSCode location
cmd /c mklink /j $vsCodeBackups $vsCodeDestination

# Create a junction point to the new ISE location
cmd /c mklink /j $ise3000 $iseDestination
