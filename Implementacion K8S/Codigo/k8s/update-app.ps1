param(
    [Parameter(Mandatory=$true)][ValidateSet('ui','gateway','users','pharmacy')][string]$App,
    [Parameter(Mandatory=$true)][string]$Image,
    [Parameter(Mandatory=$true)][string]$ProbeUrl,
    [string]$Context = 'minikube',
    [string]$ExpectBody = '',
    [switch]$Bootstrap
)
$ErrorActionPreference = 'Stop'
$nodeArgs = @("$PSScriptRoot/update-app.mjs", '--app', $App, '--image', $Image, '--probe-url', $ProbeUrl, '--context', $Context)
if ($ExpectBody) { $nodeArgs += @('--expect-body', $ExpectBody) }
if ($Bootstrap) { $nodeArgs += '--bootstrap' }
& node @nodeArgs
exit $LASTEXITCODE
