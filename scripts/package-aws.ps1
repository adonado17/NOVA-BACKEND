#requires -Version 7.0
# Reproducible API-only bundle from committed Git objects. No AWS calls or installs.
[CmdletBinding()]
param([string]$OutputPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimePaths = @('package.json', 'package-lock.json', 'src/')
$gitCommand = (Get-Command git -ErrorAction Stop).Source
$npmCommand = Get-Command npm.cmd -ErrorAction SilentlyContinue
if ($null -eq $npmCommand) { $npmCommand = Get-Command npm -ErrorAction Stop }
$strictUtf8 = [System.Text.UTF8Encoding]::new($false, $true)

function Invoke-RepositoryGit {
    param([string[]]$Arguments)
    $result = & $gitCommand -C $repositoryRoot @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Git no pudo completar la validacion o el archivo solicitado.' }
    foreach ($line in $result) { $line.ToString() }
}

function Assert-CleanRuntime {
    $changes = @(Invoke-RepositoryGit -Arguments (@('status', '--porcelain=v1', '--untracked-files=all', '--') + $runtimePaths))
    if ($changes.Count -ne 0) {
        throw 'Hay cambios sin commit en package.json, package-lock.json o src/. Confirma el runtime antes de empaquetar.'
    }
}

function Assert-AllowedPath {
    param([string]$Name)
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Contains('\') -or $Name.Contains(':') -or
        $Name.StartsWith('/') -or $Name -match '(^|/)\.\.?(/|$)' -or $Name -match '[\x00-\x1f\x7f]') {
        throw 'El archivo contiene una ruta no portable o insegura.'
    }
    if ($Name -cnotin @('package.json', 'package-lock.json') -and $Name -cnotmatch '^src/.+\.(?:js|mjs|cjs|json)$') {
        throw "Ruta fuera de la lista permitida: $Name"
    }
    if ($Name -match '(?i)(^|/)(node_modules|\.git|\.aws|\.env(?:\.[^/]*)?|\.npmrc|credentials(?:\.json)?|id_rsa|id_dsa|id_ed25519)(/|$)' -or
        $Name -match '(?i)(^|/)(?:private[-_]?key|secrets?)(?:\.[^/]*)?$') {
        throw "No se permiten archivos privados en el paquete: $Name"
    }
}

function Assert-NoEmbeddedSecret {
    param([string]$Name, [string]$Content)
    $patterns = @(
        '-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----',
        '(?i)(?:mongodb(?:\+srv)?|https?|postgres(?:ql)?|mysql|redis)://[^\s''"<>:/]+:[^\s''"<>@]+@',
        '(?<![A-Z0-9])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Z0-9])',
        '(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}',
        '(?i)[''"]?\b(?:JWT_SECRET|MONGODB_URI|AWS_SECRET_ACCESS_KEY|AWS_SESSION_TOKEN)\b[''"]?\s*[:=]\s*[''"][^''"\r\n]{8,}[''"]',
        '(?<![A-Za-z0-9_])(?:gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{30,})'
    )
    for ($index = 0; $index -lt $patterns.Count; $index++) {
        if ($Content -cmatch $patterns[$index]) {
            throw "Posible credencial en '$Name' (regla $($index + 1)); el valor no se muestra."
        }
    }
}

function Read-EntryText {
    param([System.IO.Compression.ZipArchiveEntry]$Entry)
    $reader = [System.IO.StreamReader]::new($Entry.Open(), $strictUtf8, $true)
    try { return $reader.ReadToEnd() }
    finally { $reader.Dispose() }
}

function Get-NormalizedMap {
    param($Object, [string]$Name)
    $ordered = [ordered]@{}
    if ($Object.Contains($Name)) {
        foreach ($key in ($Object[$Name].Keys | Sort-Object)) { $ordered[$key] = $Object[$Name][$key] }
    }
    return ($ordered | ConvertTo-Json -Compress -Depth 10)
}

function Assert-PackageLock {
    param($Package, $Lock)
    if (-not $Lock.Contains('packages') -or -not $Lock['packages'].Contains('')) {
        throw 'package-lock.json debe contener la entrada raiz packages[""].'
    }
    $lockRoot = $Lock['packages']['']
    foreach ($name in @('name', 'version')) {
        if ($Package[$name] -cne $Lock[$name] -or $Package[$name] -cne $lockRoot[$name]) {
            throw "package.json y package-lock.json no coinciden en '$name'."
        }
    }
    foreach ($name in @('dependencies', 'devDependencies', 'optionalDependencies', 'peerDependencies', 'engines')) {
        if ((Get-NormalizedMap $Package $name) -cne (Get-NormalizedMap $lockRoot $name)) {
            throw "package.json y package-lock.json no coinciden en '$name'."
        }
    }
    if ($Package['main'] -cne 'src/server.js' -or $Package['scripts']['start'] -cne 'node src/server.js' -or
        $Package['engines']['node'] -cne '>=24.15.0 <25') {
        throw 'El paquete debe iniciar src/server.js y usar Node >=24.15.0 <25.'
    }
}

$nodeVersion = & node -p 'process.versions.node' 2>&1
if ($LASTEXITCODE -ne 0 -or [version]$nodeVersion -lt [version]'24.15.0' -or ([version]$nodeVersion).Major -ne 24) {
    throw 'Este empaquetador requiere Node >=24.15.0 <25.'
}
Assert-CleanRuntime
$sourceCommit = (Invoke-RepositoryGit -Arguments @('rev-parse', '--verify', 'HEAD')).Trim()
$expected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$expectedDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
$tree = @(Invoke-RepositoryGit -Arguments (@('ls-tree', '-r', '--full-tree', $sourceCommit, '--') + $runtimePaths))
foreach ($line in $tree) {
    if ($line -cnotmatch '^(100644|100755) blob [0-9a-f]+\t(.+)$') {
        throw 'El runtime debe contener solo archivos regulares; no se admiten enlaces ni submodulos.'
    }
    $name = $Matches[2]
    Assert-AllowedPath $name
    if (-not $expected.Add($name)) { throw 'Git contiene rutas de runtime duplicadas.' }
    $parent = $name
    while ($parent.Contains('/')) {
        $parent = $parent.Substring(0, $parent.LastIndexOf('/'))
        [void]$expectedDirectories.Add("$parent/")
    }
}
foreach ($name in @('package.json', 'package-lock.json', 'src/app.js', 'src/server.js')) {
    if (-not $expected.Contains($name)) { throw "Falta un archivo obligatorio en HEAD: $name" }
}

# This reads committed/runtime manifests only, never .env, and installs nothing.
Push-Location $repositoryRoot
try {
    $npmDiagnostic = & $npmCommand.Source ci --dry-run --omit=dev --ignore-scripts --offline --audit=false --fund=false 2>&1
    if ($LASTEXITCODE -ne 0) { throw "npm ci --dry-run rechazo el lock (codigo $LASTEXITCODE); revisa dependencias y cache local." }
}
finally { Pop-Location }
Assert-CleanRuntime
if ((Invoke-RepositoryGit -Arguments @('rev-parse', '--verify', 'HEAD')).Trim() -cne $sourceCommit) {
    throw 'HEAD cambio durante la validacion. Ejecuta nuevamente el empaquetador.'
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) { $OutputPath = Join-Path $repositoryRoot 'outputs/nova-backend.zip' }
$absoluteOutput = [System.IO.Path]::GetFullPath($OutputPath)
if ([System.IO.Path]::GetExtension($absoluteOutput) -ine '.zip') { throw 'OutputPath debe terminar en .zip.' }
foreach ($directory in @('src', '.git', 'node_modules')) {
    $prefix = [System.IO.Path]::GetFullPath((Join-Path $repositoryRoot $directory)).TrimEnd([char[]]'\/') + [System.IO.Path]::DirectorySeparatorChar
    if ($absoluteOutput.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'La salida no puede escribirse dentro del runtime, .git ni node_modules.'
    }
}
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($absoluteOutput)) | Out-Null
$temporaryArchive = $absoluteOutput + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
try {
    Invoke-RepositoryGit -Arguments (@('archive', '--format=zip', "--output=$temporaryArchive", $sourceCommit, '--') + $runtimePaths) | Out-Null
    $zip = [System.IO.Compression.ZipFile]::OpenRead($temporaryArchive)
    try {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $seenDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $totalSize = 0L
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            $fileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if ($name.EndsWith('/')) {
                if (-not $expectedDirectories.Contains($name) -or -not $seenDirectories.Add($name) -or
                    $fileType -notin @(0, 0x4000)) { throw 'El ZIP contiene un directorio inesperado o enlazado.' }
                continue
            }
            Assert-AllowedPath $name
            if (-not $expected.Contains($name) -or -not $seen.Add($name) -or $fileType -notin @(0, 0x8000)) {
                throw 'El ZIP contiene entradas inesperadas, duplicadas o enlazadas.'
            }
            $totalSize += $entry.Length
            if ($entry.Length -gt 5MB -or $totalSize -gt 50MB) { throw 'El paquete API excede el limite de tamano permitido.' }
            Assert-NoEmbeddedSecret $name (Read-EntryText $entry)
        }
        if ($seen.Count -ne $expected.Count) { throw 'El ZIP no contiene todos los archivos de runtime de HEAD.' }
        $package = (Read-EntryText $zip.GetEntry('package.json')) | ConvertFrom-Json -AsHashtable
        $lock = (Read-EntryText $zip.GetEntry('package-lock.json')) | ConvertFrom-Json -AsHashtable
        Assert-PackageLock $package $lock
    }
    finally { $zip.Dispose() }
    [System.IO.File]::Move($temporaryArchive, $absoluteOutput, $true)
    $archiveFile = Get-Item -LiteralPath $absoluteOutput
    [pscustomobject]@{
        Archive = $archiveFile.FullName
        Files = $expected.Count
        Bytes = $archiveFile.Length
        SHA256 = (Get-FileHash -LiteralPath $absoluteOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    }
}
finally {
    # Delete only the single temporary ZIP created by this invocation; no extraction.
    if ([System.IO.File]::Exists($temporaryArchive)) { [System.IO.File]::Delete($temporaryArchive) }
}
