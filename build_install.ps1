param(
    [string]$File = "fx_trade_copper.mq5"
)

$defaultSource = "fx_trade_copper.mq5"
$workspace = (Get-Location).Path

function Get-EaVersion {
    param(
        [string]$SourcePath
    )

    $versionLine = Select-String -Path $SourcePath -Pattern '^\s*#property\s+version\s+"([^"]+)"' | Select-Object -First 1
    if ($versionLine -and $versionLine.Matches.Count -gt 0) {
        return $versionLine.Matches[0].Groups[1].Value
    }

    return "unknown"
}

function Resolve-CompileSource {
    param(
        [string]$RequestedFile,
        [string]$WorkspacePath,
        [string]$DefaultSourceName
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($RequestedFile)) {
        $requestedPath = $RequestedFile
        if (-not [System.IO.Path]::IsPathRooted($requestedPath)) {
            $requestedPath = Join-Path $WorkspacePath $requestedPath
        }

        if ((Test-Path $requestedPath -PathType Leaf) -and ([System.IO.Path]::GetExtension($requestedPath).ToLowerInvariant() -eq ".mq5")) {
            $candidates.Add((Resolve-Path $requestedPath).Path)
        }

        $candidateDir = [System.IO.Path]::GetDirectoryName($requestedPath)
        if ([string]::IsNullOrWhiteSpace($candidateDir)) {
            $candidateDir = $WorkspacePath
        }

        $candidateMq5 = Join-Path $candidateDir (([System.IO.Path]::GetFileNameWithoutExtension($requestedPath)) + ".mq5")
        if (Test-Path $candidateMq5 -PathType Leaf) {
            $candidates.Add((Resolve-Path $candidateMq5).Path)
        }
    }

    $defaultPath = Join-Path $WorkspacePath $DefaultSourceName
    if (Test-Path $defaultPath -PathType Leaf) {
        $candidates.Add((Resolve-Path $defaultPath).Path)
    }

    $uniqueCandidates = @($candidates | Select-Object -Unique)
    if ($uniqueCandidates.Count -gt 0) {
        return [string]$uniqueCandidates[0]
    }

    $mq5Files = Get-ChildItem -Path $WorkspacePath -Filter *.mq5 -File
    if ($mq5Files.Count -eq 1) {
        return $mq5Files[0].FullName
    }

    if ($mq5Files.Count -gt 1) {
        $names = ($mq5Files | Select-Object -ExpandProperty Name) -join ", "
        throw "Could not determine which MQ5 file to compile. Available sources: $names"
    }

    throw "No MQ5 source file was found to compile."
}

$FilePath = Resolve-CompileSource -RequestedFile $File -WorkspacePath $workspace -DefaultSourceName $defaultSource
$expertOutputPath = [System.IO.Path]::ChangeExtension($FilePath, ".ex5")
$sourceName = [System.IO.Path]::GetFileNameWithoutExtension($FilePath)
$expertFileName = [System.IO.Path]::GetFileName($expertOutputPath)
$compilePath = [string]$FilePath
$eaVersion = Get-EaVersion -SourcePath $FilePath
$buildRoot = Join-Path $workspace "build"
$buildArtifactPath = Join-Path $buildRoot $expertFileName
$buildLogPath = Join-Path $workspace ("metaeditor-" + $sourceName + ".log")
$sourceBuildBefore = $null

if (Test-Path $expertOutputPath) {
    $sourceBuildBefore = (Get-Item $expertOutputPath).LastWriteTimeUtc
}

New-Item -ItemType Directory -Force -Path $buildRoot | Out-Null
if (Test-Path $buildArtifactPath) {
    Remove-Item -Path $buildArtifactPath -Force
}

# 2. Discover Terminal Path
$appData = [Environment]::GetFolderPath("ApplicationData")
$terminalsPath = Join-Path $appData "MetaQuotes\Terminal"

# 2. Discover MetaEditor
$metaEditorPaths = @(
    "C:\Program Files\MetaTrader 5\metaeditor64.exe",
    "C:\Program Files\MetaTrader 5\metaeditor.exe",
    "C:\Program Files (x86)\MetaTrader 5\metaeditor.exe"
)

$metaEditor = $null
foreach ($path in $metaEditorPaths) {
    if (Test-Path $path) {
        $metaEditor = $path
        break
    }
}

if (-not $metaEditor) {
    Write-Host "Could not find MetaEditor! Please ensure MetaTrader 5 is installed." -ForegroundColor Red
    exit 1
}

Write-Host "Compiling ${compilePath}..." -ForegroundColor Cyan
Write-Host "Build artifact will be stored in: $buildArtifactPath" -ForegroundColor DarkCyan
Write-Host "Detected EA version: $eaVersion" -ForegroundColor DarkCyan

# 3. Compile the file
$compileArgs = @("/compile:`"$compilePath`"", "/log:`"$buildLogPath`"")
$process = Start-Process -FilePath $metaEditor -ArgumentList $compileArgs -Wait -NoNewWindow -PassThru

# 4. Verify & Deploy
if (Test-Path $expertOutputPath) {
    $sourceBuildAfter = (Get-Item $expertOutputPath).LastWriteTimeUtc
    if ($null -ne $sourceBuildBefore -and $sourceBuildAfter -le $sourceBuildBefore) {
        Write-Host "Compilation did not produce a newer EX5 file. Build log: $buildLogPath" -ForegroundColor Red
        exit 1
    }

    Write-Host "Compilation successful!" -ForegroundColor Green

    try {
        Copy-Item -Path $expertOutputPath -Destination $buildArtifactPath -Force -ErrorAction Stop
    }
    catch {
        Write-Host "Failed to copy build artifact to: $buildArtifactPath" -ForegroundColor Red
        Write-Host $_.Exception.Message -ForegroundColor DarkRed
        exit 1
    }

    if (-not (Test-Path $buildArtifactPath)) {
        Write-Host "Build completed but no EX5 was generated inside build folder: $buildArtifactPath" -ForegroundColor Red
        exit 1
    }

    Write-Host "Saved build artifact: $buildArtifactPath" -ForegroundColor Yellow
    Write-Host "Saved build log: $buildLogPath" -ForegroundColor Yellow
    
    if (Test-Path $terminalsPath) {
        $terminals = Get-ChildItem -Path $terminalsPath -Directory
        $installed = 0
        $failed = 0
        
        foreach ($terminal in $terminals) {
            # Skip common folder
            if ($terminal.Name -eq "Common") { continue }
            
            $expertsDir = Join-Path $terminal.FullName "MQL5\Experts"
            if (Test-Path $expertsDir) {
                $targetFile = Join-Path $expertsDir $expertFileName
                try {
                    Copy-Item -Path $expertOutputPath -Destination $targetFile -Force -ErrorAction Stop
                    Write-Host "Installed Expert Advisor to: $targetFile" -ForegroundColor Yellow
                    $installed++
                }
                catch {
                    Write-Host "Failed to install Expert Advisor to: $targetFile" -ForegroundColor Red
                    Write-Host $_.Exception.Message -ForegroundColor DarkRed
                    $failed++
                }
            }
        }
        
        if ($installed -gt 0) {
            Write-Host -ForegroundColor Green "Successfully deployed to $installed terminal(s)!"
        }

        if ($failed -gt 0) {
            Write-Host -ForegroundColor Yellow "Deployment failed for $failed terminal(s)."
        }

        if ($installed -eq 0 -and $failed -eq 0) {
            Write-Host -ForegroundColor Red "Warning: Could not find MQL5\Experts directory in any MT5 terminal folder."
        }
    } else {
        Write-Host -ForegroundColor Red "Warning: MetaQuotes Terminal user path not found."
    }
} else {
    Write-Host "Compilation failed. Build log: $buildLogPath" -ForegroundColor Red
    exit 1
}
