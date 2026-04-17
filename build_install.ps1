param(
    [string]$File = "fx_trade_copper.mq5"
)

$defaultSource = "fx_trade_copper.mq5"
$workspace = (Get-Location).Path

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
$expertFileName = [System.IO.Path]::GetFileName($expertOutputPath)
$compilePath = [string]$FilePath

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

# 3. Compile the file
$compileArgs = @("/compile:`"$compilePath`"", "/log")
$process = Start-Process -FilePath $metaEditor -ArgumentList $compileArgs -Wait -NoNewWindow -PassThru

# 4. Verify & Deploy
if (Test-Path $expertOutputPath) {
    Write-Host "Compilation successful!" -ForegroundColor Green
    
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
    Write-Host "Compilation failed. A log file has been created near your mq5 script." -ForegroundColor Red
}
