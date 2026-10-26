# Requires the user's existing TrustInstaller-Start command; does not change login startup.
param([Parameter(Mandatory=$true)][string]$Request)
$ErrorActionPreference='Stop'
try {
    $requestData=Get-Content -LiteralPath $Request -Raw | ConvertFrom-Json
    . $requestData.Profile
    $command=Get-Command TrustInstaller-Start -ErrorAction Stop
    if(-not $command.Parameters.ContainsKey('CommandLine')) { throw 'TrustInstaller-Start does not support program launch parameters.' }
    TrustInstaller-Start -CommandLine $requestData.CommandLine -WorkingDirectory $requestData.WorkingDirectory
} catch {
    @{error=$_.Exception.Message} | ConvertTo-Json -Compress | Set-Content -LiteralPath ($Request+'.ready.tmp') -Encoding utf8
    Move-Item -LiteralPath ($Request+'.ready.tmp') -Destination ($Request+'.ready') -Force
    exit 1
}
