param(
 [string]$ReleaseVersion='v0.1.0-alpha.1',
 [int]$BuildNumber=1,
 [Parameter(Mandatory=$true)][string]$ISCC
)
$ErrorActionPreference='Stop'
if($ReleaseVersion -notmatch '^v?\d+\.\d+\.\d+-alpha\.\d+$' -or $BuildNumber -lt 1 -or $BuildNumber -gt 65535){throw 'Invalid release version/build'}
$root=Split-Path $PSScriptRoot -Parent
$release=Join-Path $root ('artifacts\releases\'+$ReleaseVersion)
$publish=Join-Path $release 'windows-x64'
$packageVersion=$ReleaseVersion.TrimStart('v')
$baseVersion=$packageVersion.Split('-')[0]
$numeric=$baseVersion+'.'+$BuildNumber
$assemblyVersion=$baseVersion+'.0'
New-Item -ItemType Directory -Path $release -Force|Out-Null
dotnet publish (Join-Path $root 'windows\ShareMouse\ShareMouse.csproj') -c Release -r win-x64 --self-contained true --artifacts-path (Join-Path $release 'dotnet-build') --disable-build-servers -o $publish -p:Version=$packageVersion -p:AssemblyVersion=$assemblyVersion -p:FileVersion=$numeric -p:PublishSingleFile=false -p:PublishTrimmed=false -p:DebugType=None -p:DebugSymbols=false
if($LASTEXITCODE -ne 0){exit $LASTEXITCODE}
foreach($name in @('ShareMouse.exe','ShareMouse.dll','ShareMouse.Core.dll','ShareMouse.Network.dll','hostfxr.dll','coreclr.dll','msquic.dll','bridge.py','computer_client.py','keyboard-layouts.json','keyboard-icons.svg')) {
 if(-not(Test-Path -LiteralPath (Join-Path $publish $name))){throw ('Missing release payload: '+$name)}
}
if(-not(Test-Path -LiteralPath $ISCC)){throw 'Inno Setup 7 x64 compiler missing'}
$arguments='/Qp /DReleaseVersion='+$ReleaseVersion+' /DNumericVersion='+$numeric+' /DPublishDir="'+$publish+'" /DOutputDirPath="'+$release+'" "'+(Join-Path $root 'packaging\windows\ShareMouse.iss')+'"'
$stdout=Join-Path $release 'installer-build.log';$stderr=Join-Path $release 'installer-build-errors.log'
$process=Start-Process -FilePath $ISCC -ArgumentList $arguments -PassThru -WindowStyle Hidden -RedirectStandardOutput $stdout -RedirectStandardError $stderr
$null=$process.Handle
$watch=[Diagnostics.Stopwatch]::StartNew()
while(-not $process.WaitForExit(200)) {
 $process.Refresh()
 if($process.PrivateMemorySize64 -gt 768MB -or $watch.Elapsed.TotalSeconds -gt 180){$process.Kill();throw 'Installer compiler exceeded its resource budget'}
}
$process.WaitForExit()
if($null -eq $process.ExitCode){throw 'Installer compiler returned no exit code'}
if($process.ExitCode -ne 0){[Console]::Error.WriteLine([IO.File]::ReadAllText($stderr));[Console]::Error.WriteLine([IO.File]::ReadAllText($stdout));exit $process.ExitCode}
$installer=Join-Path $release ('ShareMouse-'+$ReleaseVersion+'-windows-x64-setup.exe')
if(-not(Test-Path -LiteralPath $installer)){throw 'Installer missing'}
[Console]::WriteLine('Installer: '+$installer)
