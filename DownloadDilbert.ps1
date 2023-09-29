# This uses rharish101's excellent dilbert-viewer to download any/all Dilbert comics.
# Some Urls from the viewer may fail to download. This can be run multiple times to retry failing downloads.
# There's some kind of bug in the viewer and 2011-12-01 is unavailable. This is a working URL to that strip:
# https://assets.amuniversal.com/9cac4f702f4c01348bea005056a9545d

# The Url for the viewer page.
$viewerUrl = "https://dilbert-viewer.herokuapp.com"

# The path to store downloads
$folder = "C:\Users\scott\OneDrive\Dilbert"

# The range of dates to download
$startDate = [datetime]'1989-04-16'
$endDate   = [datetime]'2023-03-12'

do {
    # Flush any existing results
    $request = $null

    # Get a string version of the date to use in the filename.
    $dateString = $startDate.ToString('yyyy-MM-dd')

    # Full path to download to. An extension will be added later once its determined.
    $path = "$folder\$dateString"

    # Since a title may be appended to the date, check for any file that starts with the date. Download if it doesn't exist.
    if (Test-Path -Path "$path*") {
        Write-Verbose "$dateString already downloaded."
    } else {
        try {
            Write-Host "Downloading $dateString." -ForegroundColor Green

            # Download the page from the viewer
            $request = Invoke-WebRequest -UseBasicParsing -Uri "$viewerUrl/$dateString"
        } catch {
            Write-Warning "$dateString page not found on server."
        }
    }

    if ($request) {
        # Get the title of the page and append it to the file name if its not the generic title.
        if ($request.Content -match '<title>(?<Title>.*) - Dilbert Viewer</title>') {
            $title = $Matches.Title.Trim()
            if ($title -ne "Comic Strip on $dateString") {
                $path = "$path - $title".Trim(' .')
            }
        }

        # Get the URL to download the pic from
        if ($request.Content -match '(?<URL>http(s)?://assets.amuniversal.com/[a-f|0-9]{32})') {
            $picLink = $Matches.URL
        } else {
            $picLink = $null
        }

        if ($picLink) {
            try {
                # Download the pic
                $download = Invoke-WebRequest -UseBasicParsing -Uri $picLink -OutFile $path -PassThru
                $extension = $download.Headers.'Content-Disposition'.Split('.')[-1].Trim('"')
                Rename-Item -Path $path -NewName "$path.$extension"
                #$filename = $download.Headers.'Content-Disposition'.Split('"')[-2]
                #Rename-Item -Path $path -NewName "$path - $filename"
            } catch {
                Write-Warning "Error downloading $dateString."
            }
        } else {
            Write-Warning "Link not found for $dateString"
        }
    }
    $startDate = $startDate.AddDays(1)
} until ($startDate -gt $endDate)
