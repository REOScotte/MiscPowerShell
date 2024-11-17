$root = 'C:\Users\scott\OneDrive\Source\Repos\'
Set-Location $root

$repos = Get-ChildItem .git -Recurse -Directory -Force

git config --global user.name REOScotte
git config --global user.email 11577865+REOScotte@users.noreply.github.com

$evangelRepos = @(
    'Business Intelligence'
    'EvangelSQL'
    'Integrations'
    'Legacy Website'
    'Systems.dotNet'
    'Systems.PowerShell'
    'Z'
)

$jhaRepos = @(
    'CPSOps'
    'EPSOps'
    'HPS'
    'JHA'
)

$repos | ForEach-Object {
    $repo = $_
    Push-Location $repo.Parent.FullName
    $path = $repo.Parent.FullName.Replace($root, '')

    if ($path -in $evangelRepos) {
        git config --local user.name Crawfords.BI
        git config --local user.email 
    } elseif ($path -in $JHARepos) {
        git config --local user.name 'Scott Crawford'
        git config --local user.email 
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