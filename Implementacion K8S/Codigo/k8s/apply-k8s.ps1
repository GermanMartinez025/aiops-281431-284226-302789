param([Parameter(Mandatory=$true)][string]$Tag, [string]$Context = 'minikube')
$ErrorActionPreference = 'Stop'
& node "$PSScriptRoot/install.mjs" --tag $Tag --context $Context
exit $LASTEXITCODE
