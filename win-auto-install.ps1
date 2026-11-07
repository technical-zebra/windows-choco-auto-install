# auto-install.ps1
# Part of code please refer to winget-install.ps1 in gitcode.com
# author: Terry, githcode.com


# Find the WinGet Executable Loaction (for use when running in SYSTEM context)
function Find-WinGet {
    try {
        # Get the WinGet path
        $WinGetPathToResolve = Join-Path -Path $ENV:ProgramFiles -ChildPath 'WindowsApps\Microsoft.DesktopAppInstaller_*_*__8wekyb3d8bbwe'
        $ResolveWinGetPath = Resolve-Path -Path $WinGetPathToResolve -ErrorAction Stop | Sort-Object {
            [version]($_.Path -replace '^[^\d]+_((\d+\.)*\d+)_.*', '$1')
        }

        if ($ResolveWinGetPath) {
            # If we have multiple versions - use the latest.
            $WinGetPath = $ResolveWinGetPath[-1].Path
        }

        $WinGet = Join-Path $WinGetPath 'winget.exe'

        # Test if WinGet Executable exists
        if (Test-Path -Path $WinGet) {
            return $WinGet
        } else {
            return $null
        }
    } catch {
        Write-Debug "Could not resolve winget path: $($_.Exception.Message)"
        return $null
    }
}

# Check if winget is installed or not
function Get-WingetStatus {
    <#
        .SYNOPSIS
        Checks if winget is installed.

        .DESCRIPTION
        This function checks if winget is installed.

        .EXAMPLE
        Get-WingetStatus
    #>

    # Check if winget is installed
    if ($RunAsSystem) {
        $wingetPath = Find-WinGet
        if ($null -ne $wingetPath) {
            $winget = & $wingetPath -v
        } else {
            $winget = $null
        }
    } else {
        $winget = Get-Command -Name winget -ErrorAction SilentlyContinue
    }

    # If winget is installed, return $true
    if ($null -ne $winget -and $winget -notlike '*failed to run*') {
        return $true
    }

    # If winget is not installed, return $false
    return $false
}

function Install-Packetmanager() {
	try {
		# Check if winget is already installed
		if (Get-WingetStatus) {
			if ($Force -eq $false) {
				Write-Warning "winget is already installed, exiting..."
				Write-Warning "If you want to reinstall winget, run the script with the -Force parameter."
				ExitWithDelay 0 5
			}
		}
		
		# ============================================================================ #
		# Install using the regular method, Windows 10+
		# ============================================================================ #

		if (
			$osVersion.NumericVersion -notin 2019, 2022 -and
			$osVersion.InstallationType -ne 'Server Core' -and
			-not $AlternateInstallMethod -and
			-not $RunAsSystem
		) {
			Write-Section "winget"

			# If WingetVersion is specified, warn user it only works when using the -AlternateInstallMethod.
			if ($WingetVersion -ne 'latest') {
				Write-Warning "The -WingetVersion parameter is ignored when not using -AlternateInstallMethod. The standard install method always installs the latest version."
			}

			try {
				Write-Debug "Checking if NuGet PackageProvider is already installed..."
				Install-NuGetIfRequired

				Write-Output "Installing Microsoft.WinGet.Client module (latest)..."
				Install-Module -Name Microsoft.WinGet.Client -Force -AllowClobber -Repository PSGallery -ErrorAction SilentlyContinue *>&1 | Out-Null

				Write-Output "Installing winget (this takes a minute or two)..."
				try { Repair-WinGetPackageManager -AllUsers -Force -Latest *>&1 | Out-Null } catch { }

			} catch {
				$errorHandled = Handle-Error $_
				if ($null -ne $errorHandled) {
					throw $errorHandled
				}
				$errorHandled = $null
			}

			# Add to environment PATH to avoid issues when usernames or user profile paths change, or when using non-Latin characters (see #45)
			# Adding with literal %LOCALAPPDATA% to ensure it isn't resolved to the current user's LocalAppData as a fixed path
			Add-ToEnvironmentPath -PathToAdd "%LOCALAPPDATA%\Microsoft\WindowsApps" -Scope 'User'
		}

		# ============================================================================ #
		#  Server 2019 or alternate install method only
		# ============================================================================ #

		if (
			(
				$osVersion.Type -eq 'Server' -and
				$osVersion.NumericVersion -in 2019, 2022 -and
				$osVersion.InstallationType -ne 'Server Core'
			) -or
			$AlternateInstallMethod -or
			$RunAsSystem
		) {

			# ============================================================================ #
			# Dependencies
			# ============================================================================ #

			Write-Section "Dependencies"
			Write-Debug "GHtoken=$GHtoken"

			try {
				# Download winget dependencies (VCLibs.140.00.UWPDesktop and UI.Xaml.2.8)
				$winget_dependencies_path = New-TemporaryFile2
				try {
					$winget_dependencies_url = Get-WingetDownloadUrl -Match 'DesktopAppInstaller_Dependencies.zip' -WingetVersion $WingetVersion -GHtoken $GHtoken
				} catch {
					# If we can't get the dependencies of the exact version the user wants, fall back to try to find another version that has them
					$winget_dependencies_url = Get-WingetDownloadUrl -Match 'DesktopAppInstaller_Dependencies.zip' -GHtoken $GHtoken
				}

				Write-Output 'Downloading winget dependencies...'
				Write-Debug "Downloading winget dependencies from $winget_dependencies_url to $winget_dependencies_path`n`n"
				Invoke-WebRequest -Uri $winget_dependencies_url -OutFile $winget_dependencies_path

				# Load ZIP assembly to read the package contents
				Add-Type -AssemblyName System.IO.Compression.FileSystem
				$zip = [System.IO.Compression.ZipFile]::OpenRead($winget_dependencies_path)

				$matchingEntries = $zip.Entries | Where-Object { $_.FullName -match ".*$arch.appx" }
				if ($matchingEntries) {
					$matchingEntries | ForEach-Object {
						$destPath = Join-Path ([System.IO.Path]::GetTempPath()) $_.Name
						Write-Debug "Extracting $($_.FullName) to $destPath..."
						[System.IO.Compression.ZipFileExtensions]::ExtractToFile($_, $destPath, $true)

						$AppName = Get-ManifestProperty -Lib_Path $destPath -Property Name
						Write-Output "Installing $AppName..."
						Install-LibIfRequired -Lib_Name $AppName -Lib_Path $destPath
						Write-Debug "Removing temporary library file..."
						TryRemove $destPath
					}
					$zip.Dispose()
				} else {
					Write-Error "Dependency not found inside the file: $winget_dependencies_path"
				}

				Write-Debug "Removing temporary files..."
				TryRemove $winget_dependencies_path

			} catch {
				$errorHandled = Handle-Error $_
				if ($null -ne $errorHandled) {
					throw $errorHandled
				}
				$errorHandled = $null
			}

			# ============================================================================ #
			#  winget
			# ============================================================================ #

			Write-Section "winget"

			try {

				# Download winget license
				$winget_license_path = New-TemporaryFile2
				try {
					$winget_license_url = Get-WingetDownloadUrl -Match "License1.xml" -WingetVersion $WingetVersion -GHtoken $GHtoken
				} catch {
					# If we can't get the license XML of the exact version the user wants, fall back to try to find another version that has it
					$winget_license_url = Get-WingetDownloadUrl -Match "License1.xml" -GHtoken $GHtoken
				}
				Write-Output "Downloading winget license..."
				Write-Debug "Downloading winget license from $winget_license_url to $winget_license_path`n`n"
				Invoke-WebRequest -Uri $winget_license_url -OutFile $winget_license_path

				# Download winget
				$winget_path = New-TemporaryFile2
				$winget_url = Get-WingetDownloadUrl -Match 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle' -WingetVersion $WingetVersion -GHtoken $GHtoken
				Write-Output "Downloading winget..."
				Write-Debug "Downloading winget from $winget_url to $winget_path`n`n"
				Invoke-WebRequest -Uri $winget_url -OutFile $winget_path

				# Install winget
				Write-Output "Installing winget..."
				Add-AppxProvisionedPackage -Online -PackagePath $winget_path -LicensePath $winget_license_path | Out-Null

				# Remove temporary files
				Write-Debug "Removing temporary files..."
				TryRemove $winget_path
				TryRemove $winget_license_path
			} catch {
				$errorHandled = Handle-Error $_
				if ($null -ne $errorHandled) {
					throw $errorHandled
				}
				$errorHandled = $null
			}

			# ============================================================================ #
			# Visual C++ Redistributable
			# ============================================================================ #

			Write-Section "Visual C++ Redistributable"

			# Test if Visual C++ Redistributable is not installed
			if (!(Test-VCRedistInstalled)) {
				Write-Debug "Visual C++ Redistributable is not installed.`n`n"

				# Define the URL and temporary file path for the download
				$VCppRedistributable_Url = "https://aka.ms/vs/17/release/vc_redist.${arch}.exe"
				$VCppRedistributable_Path = New-TemporaryFile2
				Write-Output "Downloading Visual C++ Redistributable..."
				Write-Debug "Downloading Visual C++ Redistributable from $VCppRedistributable_Url to $VCppRedistributable_Path`n`n"
				Invoke-WebRequest -Uri $VCppRedistributable_Url -OutFile $VCppRedistributable_Path

				# Rename file
				$VCppRedistributableExe_Path = $VCppRedistributable_Path + ".exe"
				Rename-Item -Path $VCppRedistributable_Path -NewName $VCppRedistributableExe_Path

				# Install Visual C++ Redistributable
				Write-Output "Installing Visual C++ Redistributable..."
				Write-Debug "Installing Visual C++ Redistributable from $VCppRedistributableExe_Path`n`n"
				Start-Process -FilePath $VCppRedistributableExe_Path -ArgumentList "/install", "/quiet", "/norestart" -Wait

				Write-Debug "Removing temporary file..."
				TryRemove $VCppRedistributableExe_Path
			} else {
				Write-Output "Visual C++ Redistributable is already installed."
			}

			# ============================================================================ #
			# Fix environment PATH and permissions
			# ============================================================================ #
			Apply-PathPermissionsFixAndAddPath -OSVersion $osVersion
		}

		# ============================================================================ #
		# Force registration
		# ============================================================================ #

		$WingetPackageFamilyName = 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe'

		if (
			$osVersion.NumericVersion -notin 2019, 2022 -and
			$osVersion.InstallationType -ne 'Server Core' -and
			-not $RunAsSystem -and
			-not $AlternateInstallMethod
		) {
			$WingetPackage = Get-AppxPackage -AllUsers -Name $WingetPackageFamilyName -ErrorAction SilentlyContinue

			if ($null -ne $WingetPackage) {
				Write-Debug 'Registering winget...'
				try {
					Add-AppxPackage -RegisterByFamilyName -MainPackage $WingetPackageFamilyName
				} catch { }
			} else {
				Write-Debug 'Winget package not found. Skipping registration.'
			}
		} else {
			Write-Debug 'Not registering winget...'
		}

		# ============================================================================ #
		#  Done
		# ============================================================================ #
	
		Write-Section "Complete"
		
		Write-Output "winget installed successfully."
		
		# ============================================================================ #
		#  Install chocolatey
		# ============================================================================ #
		
		Write-Section "Install chocolatey"
		
		try {
				$appName = "chocolatey"
				& winget install $appName 
				
		} catch { }
				
		
		
		Write-Output "chocolatey installed successfully."
		
		
	} catch {
		Write-Debug "Could not install packet manager "
	}
}

function Install-Applications() {
	
	try {
			$input = Read-Host "
Please enter the selected numbers (separated by commas, such as 1,3): `n 0. Install all by default `n 1. Cancel the installation of Firefox `n 2. Cancel the installation of WeChat `n 3.Cancel the installation of snappy-driver-installer-origin `n 4.Cancel the installation of LibreOffice `n 5.Cancel the installation of SumatraPDF `n 6.Cancel the installation of PotPlayer `n 7.Cancel the installation of GIMP `n 8.Cancel the installation of SpaceSniffer "
			$selections = $input -split ','
			& choco install firefox wechat snappy-driver-installer-origin libreoffice sumatrapdf gimp spacesniffer
			
			foreach ($f in $fruits) {
				if (($f -eq 0) -or ($f -eq "0")) {
					Write-Output "Completed all software installation"
				}
				
				if (($f -eq 1) -or ($f -eq "1")) {
					& choco uninstall firefox
				}
				
				if (($f -eq 2) -or ($f -eq "2")) {
					& choco uninstall wechat
				}
				
				if (($f -eq 3) -or ($f -eq "3")) {
					& choco uninstall firefox
				}
				
				if (($f -eq 4) -or ($f -eq "4")) {
					& choco uninstall snappy-driver-installer-origin
				}
				
				if (($f -eq 5) -or ($f -eq "5")) {
					& choco uninstall libreoffice
				}
				
				if (($f -eq 6) -or ($f -eq "6")) {
					& choco uninstall sumatrapdf
				}
				
				if (($f -eq 7) -or ($f -eq "7")) {
					& choco uninstall gimp
				}
				
				if (($f -eq 7) -or ($f -eq "7")) {
					& choco uninstall spacesniffer
				}
			}
	
	} catch { 
		
		Write-Debug "Could not install packet manager "
	}
}

& Install-Packetmanager
& Install-Applications