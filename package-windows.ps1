[CmdletBinding()]
param([switch]$EmbedMfiKey = $true, [string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = $PSScriptRoot
$win = Join-Path $root 'windows'
$modern = Join-Path $root 'swift/Host/ModernBackend'
$accessory = Join-Path $root 'swift/Host/IAP2Client'
$mfi = Join-Path $root 'asset/mfi'
function Run([string]$program, [string[]]$arguments) {
    & $program @arguments
    if ($LASTEXITCODE -ne 0) { throw "$program exited with $LASTEXITCODE" }
}
foreach ($file in @("$modern/portable_location.py","$modern/requirements.txt","$accessory/src/accessory_location/cli.py","$accessory/NOTICE","$mfi/certificate.p7b")) {
    if (!(Test-Path -LiteralPath $file -PathType Leaf)) { throw "Missing required project file: $file" }
}
if ($EmbedMfiKey -and !(Test-Path "$mfi/identity.pk8" -PathType Leaf)) {throw 'Missing asset/mfi/identity.pk8'}
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
    Run 'py' @('-3.13','-c','import sys,ssl; assert sys.maxsize > 2**32 and ssl.HAS_PSK')
    $venv = Join-Path $root 'Build/Windows-Python'
    if (!(Test-Path "$venv/Scripts/python.exe")) {Run 'py' @('-3.13','-m','venv',$venv)}
    $py="$venv/Scripts/python.exe"
    Run $py @('-m','pip','install','-r',"$modern/requirements.txt",'-r',"$win/requirements.txt")
    Run $py @('-m','pip','check')
    $stage = Join-Path $temp 'dist'
    $common = @('-m','PyInstaller','--noconfirm','--clean','--noupx','--distpath',$stage,'--workpath',"$temp/work",'--specpath',$temp,'--paths',$modern,'--paths',"$accessory/src",'--exclude-module','pytest','--exclude-module','IPython')
    $deviceDependencies = @('--recursive-copy-metadata','pymobiledevice3','--collect-data','pymobiledevice3','--collect-data','developer_disk_image','--collect-submodules','pytcp')
    Run $py ($common + $deviceDependencies + @('--name','Everywhere','--windowed','--onedir','--hidden-import','portable_location','--collect-submodules','bleak.backends.winrt','--copy-metadata','keyring','--hidden-import','keyring.backends.Windows',"$win/app.py"))
    Run $py ($common + @('--name','EverywhereWorker','--console','--onefile',"$win/worker.py"))
    $dest = "$stage/Everywhere"
    Copy-Item "$stage/EverywhereWorker.exe" $dest
    Run 'cl.exe' @('/nologo','/std:c++17','/EHsc','/O2','/MT','/utf-8',"/Fo$temp/rfcomm.obj","/Fe$dest/rfcomm.exe","$win/native/rfcomm.cpp",'ws2_32.lib','Bthprops.lib')
    Run 'cl.exe' @('/nologo','/std:c++17','/EHsc','/O2','/MT','/utf-8',"/Fo$temp/gatt.obj","/Fe$dest/EverywhereGatt.exe","$win/native/gatt.cpp",'windowsapp.lib')
    $identityDir = Join-Path $dest 'asset/mfi'
    $null = New-Item -ItemType Directory -Path $identityDir -Force
    Copy-Item "$mfi/certificate.p7b" $identityDir
    if ($EmbedMfiKey) {Copy-Item "$mfi/identity.pk8" $identityDir}
    $src = "$dest/source"
    $null = New-Item -ItemType Directory "$src/swift/Host/IAP2Client" -Force
    foreach ($name in @('LICENSE','NOTICE','src','README.md','main.py')) {Copy-Item "$accessory/$name" "$src/swift/Host/IAP2Client/" -Recurse}
    Copy-Item $win "$src/windows" -Recurse
    Copy-Item "$root/package-windows.ps1" $src
    Copy-Item $modern "$src/swift/Host/ModernBackend" -Recurse
    Get-ChildItem $src -Directory -Recurse -Filter '__pycache__' | Remove-Item -Recurse -Force
    Run "$dest/EverywhereWorker.exe" @('--self-test')
    Run "$dest/EverywhereWorker.exe" @('connect','--help')
    if ($EmbedMfiKey) {Run "$dest/EverywhereWorker.exe" @('--verify-bundle')}
    $smoke = Start-Process -Wait -PassThru -FilePath "$dest/Everywhere.exe" -ArgumentList '--smoke-test'
    if ($smoke.ExitCode -ne 0) {throw 'Packaged Qt startup or dependency check failed'}
    Run $py @('-m','unittest','discover','-s',"$win/tests",'-p','test_*.py')
    $archive = "Everywhere-Windows-x64-"+(Get-Date -Format 'yyyyMMdd-HHmmss')+'-'+[guid]::NewGuid().ToString('N').Substring(0,6)+'.zip'
    # tar includes hidden Qt files and does not impose Compress-Archive's individual file size limit.
    Run 'tar.exe' @('-a','-cf',"$temp/$archive",'-C',$stage,'Everywhere')
    Move-Item -LiteralPath "$temp/$archive" -Destination (Join-Path $OutputDirectory $archive)
    Write-Output (Join-Path $OutputDirectory $archive)
} finally {
    Remove-Item -LiteralPath $temp -Recurse -Force
}
