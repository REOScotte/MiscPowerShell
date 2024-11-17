# This is the path to the root folder that holds all of the repositories.
# Be sure to include the trailing backslash.
$root = 'C:\Users\OneDrive\source\repos\'

$repos = Get-ChildItem -Path $root -Include .git -Recurse -Directory -Force

# Global settings
git config --global user.name MainName
git config --global user.email MainEmail

# Create groups of repositories that share the same settings.
$group1 = @(
    'Repo1'
    'Repo2'
)

$group2 = @(
    'Sub\Repo3'
)

$repos | ForEach-Object {
    $repo = $_
    Push-Location $repo.Parent.FullName
    $path = $repo.Parent.FullName.Replace($root, '')

    # The groups in this if block should be updated to match the groups defined above.
    # The name and email should be updated to match the desired settings.
    if ($path -in $group1) {
        git config --local user.name 'First Name'
        git config --local user.email 'First Email'
    } elseif ($path -in $group2) {
        git config --local user.name 'Second Name'
        git config --local user.email 'Second Email'
    } else {
        git config --local --unset user.name
        git config --local --unset user.email
    }

    [PSCustomObject]@{
        Path  = $path
        User  = git config --local user.name
        Email = git config --local user.email
    }
    Pop-Location
} | Format-Table -AutoSize