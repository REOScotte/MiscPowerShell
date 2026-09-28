throw "Slow down chief"
# Define the folder path
$folderPath = 'C:\dell\iCloud\Scotte\old'
Set-Location $folderPath

robocopy "C:\Users\Scotte\OneDrive\Downloads\iCloud Photos\iCloud Photos" $folderPath /mir /np



# Helper function to get 'Date Taken'
function Get-DateTaken {
    [CmdletBinding()]
    param(
        [Parameter(ValueFromPipeline)]
        [System.IO.FileInfo]$File
    )

    process {
        $shell  = New-Object -ComObject Shell.Application
        $parent = $File.FullName | Split-Path
        $folder = $shell.Namespace($parent)
    
        $item = $folder.ParseName($File.Name)
        if ($File.Extension -eq '.MP4') {
            $raw = $folder.GetDetailsOf($item, 208)  # Index 208 typically corresponds to 'Media Created'
        } else {
            $raw = $folder.GetDetailsOf($item, 12)  # Index 12 typically corresponds to 'Date taken'
        }
        $clean = ($raw -replace '[^\u0020-\u007E]', '').Trim()

        [datetime]::Parse($clean)
    }
}

$files = Get-ChildItem -Path $folderPath | Where-Object { $_.Name -like '*.jpg' -or $_.Name -like '*.jpeg' -or $_.Name -like '*.jpeg' -or $_.Name -like '*.mp4' }
foreach ($file in $files) {
    try {
        $dateTaken = $file | Get-DateTaken
    } catch {
        Write-Host "Date Taken not found for $($file.Name)"
        continue
    }

    $suffix      = $file.Name.Split('_-.')[1]
    $newBaseName = 'iPhone_' + $dateTaken.ToString("yyyyMMdd_HHmmss") + "_$suffix"
    $newJpgName  = "$newBaseName.jpg"
    $newMp4Name  = "$newBaseName.mp4"
    $newMovName  = "$newBaseName.mov"

    if ($file.Extension -eq '.MP4') {
        Rename-Item -Path $file.FullName -NewName $newMp4Name
    } else {
        Rename-Item -Path $file.FullName -NewName $newJpgName
    }

    if ($file.Extension -in @('.JPEG', '.JPG')) {
        # Check for matching .mov file and rename it
        $oldMovName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name) + ".mov"
        $oldMovPath = Join-Path $folderPath $oldMovName
        if (Test-Path $oldMovPath) {
            Rename-Item -Path $oldMovPath -NewName $newMovName
        }
    }
}

Get-ChildItem | ForEach-Object {
    $year = $_.Name.Substring(7, 4)
    $month = $_.Name.Substring(11, 2)
    move $_ "C:\Users\Scotte\OneDrive\Camera Roll\$year\$month"
}