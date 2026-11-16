param([Parameter(Mandatory=$true)][string]$Tag, [string]$Profile = 'minikube', [ValidateSet('ui','gateway','users','pharmacy')][string]$App)
$ErrorActionPreference = 'Stop'
$nodeArgs = @("$PSScriptRoot/build-images.mjs", '--tag', $Tag, '--profile', $Profile)
if ($App) { $nodeArgs += @('--app', $App) }
& node @nodeArgs
exit $LASTEXITCODE
