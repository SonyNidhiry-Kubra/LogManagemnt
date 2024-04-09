# Automating Log Management with PowerShell, Octopus Deploy, and Windows Task Scheduler
# Author : Sony Nidhiry

# Octopus Variables
$taskName = $OctopusParameters['taskName']
$repeatIntervalMinutes = $OctopusParameters['repeatIntervalMinutes']
$scriptPath = $OctopusParameters["scriptPath"]
$scriptFileName = $OctopusParameters["scriptFileName"]
$startDate = $OctopusParameters["startDate"]
$includeSubfolders = $OctopusParameters["includeSubfolders"]
$sourceFolder = $OctopusParameters["sourceFolder"]
$destinationFolder = $OctopusParameters["destinationFolder"]
$deleteOlderThanDays = $OctopusParameters["deleteOlderThanDays"]
$customFilter = $OctopusParameters["customFilter"]
$subfolders = $OctopusParameters["subfolders"]

# Default Values
if (-not $taskName) {
    $taskName = 'CopyLogsTask'
}

if (-not $repeatIntervalMinutes) {
    $repeatIntervalMinutes = '5'
}
if (-not $startDate) {
    $startDate = Get-Date -Hour 0 -Minute 0 -Second 0
}
else {
    $startDate = [System.DateTime]::ParseExact($startDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
}

if (-not $scriptFileName) {
    $scriptFileName = 'CopyLogsScript.ps1'
} elseif (-not $scriptFileName.EndsWith(".ps1")) {
    $scriptFileName += ".ps1"
}

# Ensure the script path exists
if (-not (Test-Path -Path $scriptPath -PathType Container)) {
    New-Item -Path $scriptPath -ItemType Directory | Out-Null
    Write-Host "Script path '$scriptPath' created successfully."
}

# Argument for Windows Task Scheduler
$copyLogsArguments = "-sourceFolder $('"' + $sourceFolder + '"')",
                    "-destinationFolder $('"' + $destinationFolder + '"')",
                    "-deleteOlderThanDays $('"' + $deleteOlderThanDays + '"')",
                    "-customFilter $('"' + $customFilter + '"')", 
                    "-startDate $($startDate)",
                    "-includeSubfolders $('"' + $includeSubfolders + '"')",
                    "-subfolders $('"' + $subfolders + '"')"

# PowerShell Script directory
$copyLogsScriptPath = Join-Path -Path $scriptPath -ChildPath "$scriptFileName"
$taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-ExecutionPolicy Bypass -File `"$copyLogsScriptPath`" $copyLogsArguments"

# Check if the task already exists and delete it
if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Host "Existing scheduled task '$taskName' deleted successfully."
}

# Create a new trigger for the scheduled time and repeat
$repetitionDuration = New-TimeSpan -Days 365
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $repeatIntervalMinutes) -RepetitionDuration $repetitionDuration
# For maximum duration 
# $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes $repeatIntervalMinutes) -RepetitionDuration ([System.TimeSpan]::MaxValue)


# Create principal with runlevel highest
$principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Create a task to run the PowerShell script
Register-ScheduledTask -Action $taskAction -Trigger $trigger -TaskName $taskName -Description "ExaBeam Log Copier" -Principal $principal -Force

Write-Host "Scheduled task '$taskName' created successfully with a repeat interval of $repeatIntervalMinutes minutes."
Write-Host " "
Write-Host "Argument for $taskName : -ExecutionPolicy Bypass -File $copyLogsScriptPath $copyLogsArguments"

# Save scripts to the specified path

$copyLogsScriptContent = @'
param (
    [string]$sourceFolder,
    [string]$destinationFolder,
    [string]$deleteOlderThanDays,
    [string]$customFilter,
    [string]$startDate,
    [string]$includeSubfolders,
	[string]$subFolders 
)

# Convert string to boolean
[bool]$includeSubfolders  = $includeSubfolders -eq "True"

if ($subfolders) {
    $subFolderPaths = $subFolders -split ',' | ForEach-Object { $_.Trim() }
    foreach ($subFolder in $subFolderPaths) {
		$fullSourceFolderPath = Join-Path -Path $sourceFolder -ChildPath "$subFolder"
		$fullDestinationFolderPath = Join-Path -Path $destinationFolder -ChildPath "$subFolder"

		# Ensure the source folder exists
		if (-not (Test-Path -Path $fullSourceFolderPath -PathType Container)) {
			Write-Host "Source folder does not exist: $fullSourceFolderPath"
			exit 1
		}

		# Ensure the destination folder exists, create if not
		if (-not (Test-Path -Path $fullDestinationFolderPath -PathType Container)) {
			New-Item -Path $fullDestinationFolderPath -ItemType Directory -Force | Out-Null
		}

		# Get all files from the source folder modified after the specified date
		if ($customFilter) {
			$files = Get-ChildItem -Path $fullSourceFolderPath -Recurse:$includeSubfolders | Where-Object { $_.LastWriteTime -gt $startDate -and ($_.Name -like "*$customFilter*") }
		}
		else {
			$files = Get-ChildItem -Path $fullSourceFolderPath -Recurse:$includeSubfolders | Where-Object { $_.LastWriteTime -gt $startDate }
		}

		# Copy each file to the destination folder if modified
		foreach ($file in $files) {
			$relativePath = $file.FullName.Substring($fullSourceFolderPath.Length + 1)
			$destinationPath = Join-Path -Path $fullDestinationFolderPath -ChildPath $relativePath

			if (-not (Test-Path $destinationPath) -or ($file.LastWriteTime -ne (Get-Item $destinationPath).LastWriteTime)) {
				# Create the subdirectories if they don't exist
				$subdirectories = [System.IO.Path]::GetDirectoryName($relativePath)
				$subdirectories | ForEach-Object {
					$subdirectoryPath = Join-Path -Path $fullDestinationFolderPath -ChildPath $_
					if (-not (Test-Path -Path $subdirectoryPath -PathType Container)) {
						New-Item -Path $subdirectoryPath -ItemType Directory -Force | Out-Null
					}
				}
				# Copy the file to the destination folder
				Copy-Item -Path $file.FullName -Destination $destinationPath -Force
			}

		}
	}
}
else {
    # Ensure the source folder exists
    if (-not (Test-Path -Path $sourceFolder -PathType Container)) {
        Write-Host "Source folder does not exist: $sourceFolder"
        exit 1
    }

    # Ensure the destination folder exists, create if not
    if (-not (Test-Path -Path $destinationFolder -PathType Container)) {
        New-Item -Path $destinationFolder -ItemType Directory -Force | Out-Null
    }

    # Get all files from the source folder and its subfolders modified after the specified date
    if ($customFilter) {
        $files = Get-ChildItem -Path $sourceFolder -Recurse:$includeSubfolders | Where-Object { $_.LastWriteTime -gt $startDate -and ($_.Name -like "*$customFilter*") }
    }
    else {
        $files = Get-ChildItem -Path $sourceFolder -Recurse:$includeSubfolders | Where-Object { $_.LastWriteTime -gt $startDate }
    }

   # Copy each file to the destination folder if modified
	foreach ($file in $files) {
		if ($file.PSIsContainer) {
			continue  # Skip directories
		}
		$relativePath = $file.FullName.Substring($sourceFolder.Length + 1)
		$destinationPath = Join-Path -Path $destinationFolder -ChildPath $relativePath

		# Ensure the directory structure exists before copying the file
		$directory = [System.IO.Path]::GetDirectoryName($destinationPath)
		if (-not (Test-Path -Path $directory -PathType Container)) {
			New-Item -Path $directory -ItemType Directory -Force | Out-Null
		}

		if ($file.LastWriteTime -ne (Get-Item $destinationPath).LastWriteTime) {
			Copy-Item -Path $file.FullName -Destination $destinationPath -Force
		}
	}
}

# Delete old files in destination if required
if ($deleteOlderThanDays -ne '') {
    $cutoffDate = (Get-Date).AddDays(-[int]$deleteOlderThanDays)
    Get-ChildItem -Path $destinationFolder -Recurse:$includeSubfolders | Where-Object { $_.LastWriteTime -lt $cutoffDate } | Remove-Item -Force
}

'@

$copyLogsScriptContent | Out-File -FilePath $copyLogsScriptPath -Force