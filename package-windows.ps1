[CmdletBinding()]
param([switch]$EmbedMfiKey = $true, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$qt = Join-Path $root 'qt'
$modern = Join-Path $root 'swift/Host/ModernBackend'
$accessory = Join-Path $root 'swift/Host/IAP2Client'
$mfi = Join-Path $root 'asset/mfi'
$bundleIdentity = $env:EVERYWHERE_BUNDLE_MFI_IDENTITY -ne '0'
function Run([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "$program exited with $LASTEXITCODE" }
}
# 自检只传固定开关和仓库相对路径。单独指定工作目录，支持仓库路径含空格。
function Invoke-PackageCheck([string]$name, [string]$program, [string[]]$arguments, [int]$seconds = 90) {
    Write-Host "[check] $name (timeout: ${seconds}s)"
    $start = New-Object System.Diagnostics.ProcessStartInfo
    $start.FileName = $program
    $start.Arguments = $arguments -join ' '
    $start.WorkingDirectory = $root
    $start.UseShellExecute = $false
    $process = [System.Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit($seconds * 1000)) {
            & taskkill.exe /PID $process.Id /T /F
            throw "$name timed out after ${seconds}s"
        }
        if ($process.ExitCode -ne 0) { throw "$name failed (exit $($process.ExitCode))" }
        Write-Host "[pass] $name"
    } finally {
        $process.Dispose()
    }
}
$identityFiles = @()
if ($bundleIdentity) {
    $identityFiles += 'certificate.p7b'
    if ($EmbedMfiKey) { $identityFiles += 'identity.pk8' }
}
foreach ($file in @("$modern/portable_location.py","$modern/requirements.txt","$accessory/src/accessory_location/cli.py","$accessory/NOTICE") + @($identityFiles | ForEach-Object { Join-Path $mfi $_ })) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing required project file: $file" }
}
if (!$OutputDirectory) {$OutputDirectory = Join-Path $root 'Build/Exports'}
$null = New-Item -ItemType Directory -Force -Path $OutputDirectory
$temp = Join-Path ([IO.Path]::GetTempPath()) ('Everywhere-'+[guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory $temp
try {
    if (!(Get-Command cl.exe -ErrorAction SilentlyContinue)) {
        $vswhere = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer/vswhere.exe"
        if (!(Test-Path $vswhere)) {throw 'Install Visual Studio C++ x64 build tools and the Windows 10/11 SDK.'}
        $vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
        if (!$vs) {throw 'MSVC x64 toolchain not found'}
        Import-Module "$vs/Common7/Tools/Microsoft.VisualStudio.DevShell.dll"
        Enter-VsDevShell -VsInstallPath $vs -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64'
    }
    if ($env:VSCMD_ARG_TGT_ARCH -ne 'x64') {throw 'Select the x64 Native Tools command prompt.'}
    $venv = Join-Path $root 'Build/Windows-Python'
    if (!(Test-Path "$venv/Scripts/python.exe")) {
        if ($env:EVERYWHERE_QT_PYTHON) {
            Run $env:EVERYWHERE_QT_PYTHON @('-m','venv',$venv)
        } else {
            Run 'py' @('-3.13','-m','venv',$venv)
        }
    }
    $py="$venv/Scripts/python.exe"
    Run $py @('-c',"import sys, ssl, sysconfig; assert sys.version_info[:2] == (3,13) and sysconfig.get_platform() == 'win-amd64' and ssl.HAS_PSK, 'CPython 3.13 for Windows x64 with TLS-PSK is required'")
    Run $py @('-m','pip','install','-r',"$modern/requirements.txt",'-r',"$qt/requirements.txt")
    Run $py @('-m','pip','check')
    $stage = Join-Path $temp 'dist'
    $common = @('-m','PyInstaller','--noconfirm','--clean','--noupx','--distpath',$stage,'--workpath',"$temp/work",'--specpath',$temp,'--paths',$modern,'--paths',"$accessory/src",'--exclude-module','pytest','--exclude-module','IPython')
    $deviceDependencies = @('--recursive-copy-metadata','pymobiledevice3','--collect-data','pymobiledevice3','--collect-data','developer_disk_image','--collect-submodules','pmd_pytcp')
    # pytun_pmd3 loads Wintun relative to its module, using the Python interpreter's architecture.
    $sitePackages = Join-Path $venv 'Lib/site-packages'
    $wintunDir = 'pytun_pmd3/wintun'
    $wintunBin = "$wintunDir/bin/amd64"
    $deviceDependencies += @(
        '--add-binary', "${sitePackages}/${wintunBin}/wintun.dll:${wintunBin}",
        '--add-data', "${sitePackages}/${wintunDir}/LICENSE.txt:${wintunDir}"
    )
    $appVersion = (& $py "$qt/app_version.py").Trim()
    if ($LASTEXITCODE -ne 0 -or $appVersion -notmatch '^\d+\.\d+\.\d+$') {throw 'Invalid Qt application version'}
    $versionTuple = $appVersion.Replace('.', ',') + ',0'
    $versionFile = "$temp/version.txt"
    @"
VSVersionInfo(ffi=FixedFileInfo(filevers=($versionTuple),prodvers=($versionTuple),mask=0x3f,flags=0,OS=0x40004,fileType=1,subtype=0,date=(0,0)),
  kids=[StringFileInfo([StringTable('040904b0',[StringStruct('ProductName','Everywhere'),StringStruct('FileVersion','$appVersion'),StringStruct('ProductVersion','$appVersion')])]),
        VarFileInfo([VarStruct('Translation',[1033,1200])])])
"@ | Set-Content -LiteralPath $versionFile -Encoding ASCII
    Run $py ($common + $deviceDependencies + @('--name','Everywhere','--version-file',$versionFile,'--windowed','--onedir','--hidden-import','portable_location','--collect-submodules','bleak.backends.winrt','--copy-metadata','keyring','--hidden-import','keyring.backends.Windows',"$qt/windows_entry.py"))
    $dest = "$stage/Everywhere"
    if (!(Test-Path -LiteralPath "$dest/_internal/$wintunBin/wintun.dll" -PathType Leaf)) {
        throw "Packaged Qt app is missing $wintunBin/wintun.dll"
    }
    Run $py ($common + @('--name','EverywhereWorker','--console','--onefile',"$qt/worker.py"))
    Copy-Item "$stage/EverywhereWorker.exe" $dest
    Run 'cl.exe' @('/nologo','/std:c++17','/EHsc','/O2','/MT','/utf-8',"/Fo$temp/rfcomm.obj","/Fe$dest/rfcomm.exe","$qt/native/rfcomm.cpp",'ws2_32.lib','Bthprops.lib')
    Run 'cl.exe' @('/nologo','/std:c++20','/EHsc','/O2','/MT','/utf-8',"/Fo$temp/gatt.obj","/Fe$dest/EverywhereGatt.exe","$qt/native/gatt.cpp",'windowsapp.lib')
    $identityDir = Join-Path $dest 'asset/mfi'
    $null = New-Item -ItemType Directory -Path $identityDir -Force
    foreach ($name in $identityFiles) { Copy-Item "$mfi/$name" $identityDir }
    $src = "$dest/source"
    $null = New-Item -ItemType Directory "$src/swift/Host/IAP2Client" -Force
    foreach ($name in @('LICENSE','NOTICE','src','README.md','main.py')) {Copy-Item "$accessory/$name" "$src/swift/Host/IAP2Client/" -Recurse}
    Copy-Item $qt "$src/qt" -Recurse
    Copy-Item "$root/package-windows.ps1" $src
    Copy-Item $modern "$src/swift/Host/ModernBackend" -Recurse
    Get-ChildItem $src -Directory -Recurse -Filter '__pycache__' | Remove-Item -Recurse -Force
    Invoke-PackageCheck 'RFCOMM helper' "$dest/rfcomm.exe" @('--self-test')
    Invoke-PackageCheck 'GATT helper' "$dest/EverywhereGatt.exe" @('--self-test')
    Invoke-PackageCheck 'iAP2 worker' "$dest/EverywhereWorker.exe" @('--self-test')
    Invoke-PackageCheck 'Worker connect CLI' "$dest/EverywhereWorker.exe" @('connect','--help')
    if ($identityFiles -contains 'identity.pk8') {
        Invoke-PackageCheck 'Bundled identity' "$dest/EverywhereWorker.exe" @('--verify-bundle')
    }
    $previousSmokeLog = $env:EVERYWHERE_SMOKE_LOG
    $smokeLog = Join-Path $temp 'qt-smoke.log'
    try {
        $env:EVERYWHERE_SMOKE_LOG = $smokeLog
        Invoke-PackageCheck 'Packaged Qt startup and shutdown' "$dest/Everywhere.exe" @('--smoke-test')
    } finally {
        $env:EVERYWHERE_SMOKE_LOG = $previousSmokeLog
        if (Test-Path -LiteralPath $smokeLog) { Get-Content -LiteralPath $smokeLog -Encoding UTF8 }
    }
    Invoke-PackageCheck 'Qt unit tests' $py @('-u','-m','unittest','discover','-v','-s','qt/tests','-p','test_*.py') 300
    $archive = "Everywhere-Windows-x64-$appVersion-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.zip'
    # tar includes hidden Qt files and does not impose Compress-Archive's individual file size limit.
    Write-Host "[archive] $archive"
    Run 'tar.exe' @('-a','-cf',"$temp/$archive",'-C',$stage,'Everywhere')
    Move-Item -LiteralPath "$temp/$archive" -Destination (Join-Path $OutputDirectory $archive)
    # Keep the verified native helpers available when launching qt/app.py from source.
    $devHelpers = Join-Path $root 'Build/QtHelpers/Windows'
    $null = New-Item -ItemType Directory -Force -Path "$devHelpers/asset/mfi"
    foreach ($name in @('EverywhereWorker.exe','rfcomm.exe','EverywhereGatt.exe')) {Copy-Item "$dest/$name" $devHelpers -Force}
    foreach ($name in $identityFiles) { Copy-Item "$identityDir/$name" "$devHelpers/asset/mfi/" -Force }
    Write-Output (Join-Path $OutputDirectory $archive)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
