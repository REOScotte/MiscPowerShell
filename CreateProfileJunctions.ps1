$profileFolders = @(
    #'3D Objects'
    #'Contacts'
    #'Desktop'
    #'Documents'
    #'Downloads'
    #'Favorites'
    #'Links'
    #'Music'
    #'Pictures'
    #'Saved Games'
    #'Searches'
    #'Videos'
    #'source'
)
foreach ($folder in $profileFolders) {
    $source = "$env:USERPROFILE\$folder"
    $target = "$env:USERPROFILE\OneDrive\$folder"

    #Move-Item -Path $source -Destination $target


    if (Test-Path $source) {
        Write-Warning "$source already exists."
        continue
    }

    if (-not (Test-Path $target)) {
        Write-Warning "$target does not exist."
        continue
    }

    cmd /c mklink /j $source $target
}

#Move-Item "C:\Save" "$env:USERPROFILE\OneDrive - Jack Henry & Associates"
#cmd /c mklink /j "C:\Save" "$env:USERPROFILE\OneDrive\Save"