$ErrorActionPreference = "Stop"
$Root = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$LuaSource = Join-Path $Root "Plugins\UnLua\Source\ThirdParty\Lua\lua-5.4.4\src"
$ToolDir = Join-Path $Root "Temp\LuaTools"
$LuaExe = Join-Path $ToolDir "lua54.exe"

if (-not (Test-Path -LiteralPath $LuaExe)) {
    New-Item -ItemType Directory -Force -Path $ToolDir | Out-Null
    $VsWhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
    $VsPath = & $VsWhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if (-not $VsPath) { throw "Visual Studio C++ toolchain not found" }
    $VcVars = Join-Path $VsPath "VC\Auxiliary\Build\vcvars64.bat"
    $Command = ('"{0}" >nul && cd /d "{1}" && cl /nologo /O2 onelua.c /Fe:"{2}" /link /OUT:"{2}"' -f $VcVars, $LuaSource, $LuaExe)
    cmd.exe /d /s /c $Command
    if ($LASTEXITCODE -ne 0) { throw "Failed to build temporary Lua 5.4 interpreter" }
}

# Full Content\Script sweep: a module that is never required is never compiled by
# UnLua either, so a syntax error can survive in dead code (Util\json.lua did).
$Checker = Join-Path $PSScriptRoot "check_syntax.lua"
$LuaFiles = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script") -Recurse -File -Filter *.lua
foreach ($File in $LuaFiles) {
    & $LuaExe $Checker $File.FullName
    if ($LASTEXITCODE -ne 0) { throw "Lua syntax failure: $($File.FullName)" }
}
Write-Output "Lua syntax OK: $($LuaFiles.Count) files under Content\Script"

# --- Static guards (T1 serialization convergence) -----------------------------
$RemovedModules = @(
    (Join-Path $Root "Content\Script\Gameplay\UGC\json.lua"),
    (Join-Path $Root "Content\Script\Gameplay\UGC\UGCSerialize.lua")
)
foreach ($Removed in $RemovedModules) {
    if (Test-Path -LiteralPath $Removed) {
        throw "Duplicate serialization module restored: $Removed (T1 keeps Util\json.lua as the single implementation)"
    }
}

$JsonModules = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script") -Recurse -File -Filter json.lua
if ($JsonModules.Count -ne 1) {
    throw "Expected exactly 1 json.lua under Content\Script, found $($JsonModules.Count): $($JsonModules.FullName -join ', ')"
}

$ScanFiles = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script") -Recurse -File -Filter *.lua
$ScanFiles += Get-ChildItem -LiteralPath (Join-Path $Root "Tools\UGCTests") -Recurse -File -Filter *.lua |
    Where-Object { $_.Name -ne "run_serialization.lua" }
$StaleRefs = Select-String -LiteralPath $ScanFiles.FullName -Pattern 'UGCSerialize|Gameplay\.UGC\.json' -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch '^\s*--' }
if ($StaleRefs) {
    $Detail = ($StaleRefs | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
    throw "Stale references to a removed serialization module:`n$Detail"
}
Write-Output "Serialization guards OK: single Util\json.lua implementation (no Gameplay/UGC json.lua, no UGCSerialize refs)"

# --- Static guards (T18 dead-code removal) ------------------------------------
$DeadApis = 'SaveSceneJSON|LoadSceneJSON|SerializeEditorJSON|DeserializeEditorJSON'
# Comment lines may still name the removed APIs (historical notes are fine).
$DeadRefs = Select-String -LiteralPath $ScanFiles.FullName -Pattern $DeadApis -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch '^\s*--' -and $_.Path -notlike '*\run_serialization.lua' }
if ($DeadRefs) {
    $Detail = ($DeadRefs | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
    throw "Removed serialization API reappeared (T18):`n$Detail"
}
Write-Output "Dead-code guards OK: SaveSceneJSON/LoadSceneJSON and the editor-JSON stubs stay removed"

# --- Shipping-safety guards (T19) ---------------------------------------------
# Editor-only APIs must stay inside `#if WITH_EDITOR`: DesktopPlatform is only
# added to this module when bBuildEditor, so an unguarded include breaks Shipping.
# NOTE: this is a heuristic net. The authoritative check is a real Shipping
# build (see docs/knowledge/RISKS_AND_GAPS.md — the 2026-09-14 probe found
# InventoryGridComponent.cpp including IDetailTreeNode.h, which this now covers).
function Get-EditorGuardRanges {
    param([string[]]$Lines)
    $ranges = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -match '^\s*#\s*if') {
            $stack.Add([pscustomobject]@{ IsEditor = ($Lines[$i] -match 'WITH_EDITOR'); Start = $i })
        } elseif ($Lines[$i] -match '^\s*#\s*endif' -and $stack.Count -gt 0) {
            $open = $stack[$stack.Count - 1]
            $stack.RemoveAt($stack.Count - 1)
            if ($open.IsEditor) { $ranges.Add([pscustomobject]@{ Start = $open.Start; End = $i }) }
        }
    }
    return $ranges
}

$EditorOnlyIncludes = 'DesktopPlatformModule\.h|IDesktopPlatform\.h|IDetailTreeNode\.h|IDetailLayoutBuilder\.h|IPropertyHandle\.h|IPropertyTypeCustomization\.h|PropertyEditor|UnrealEd|DetailCustomizations|AssetTools|EditorStyle|EditorSubsystem\.h|LevelEditor|KismetEditorUtilities|ObjectTools\.h|FileHelpers\.h'
$IncludeRule = '^\s*#\s*include\s+["<].*(' + $EditorOnlyIncludes + ')'
$EditorOnlySymbols = 'FDesktopPlatformModule|FPropertyEditorModule|FLevelEditorModule|IDetailLayoutBuilder|GEditor\b'

$Unguarded = New-Object System.Collections.Generic.List[string]
foreach ($File in (Get-ChildItem -LiteralPath (Join-Path $Root "Source\FPS") -Recurse -File -Include *.h,*.cpp)) {
    $Lines = [System.IO.File]::ReadAllLines($File.FullName)
    $Ranges = Get-EditorGuardRanges -Lines $Lines
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $Line = $Lines[$i]
        $Suspect = ($Line -match $IncludeRule) -or ($Line -match '^\s*//' -and $false)
        if (-not $Suspect -and $Line -notmatch '^\s*(//|\*)') { $Suspect = ($Line -match $EditorOnlySymbols) }
        if ($Suspect) {
            $Guarded = $false
            foreach ($Range in $Ranges) { if ($i -ge $Range.Start -and $i -le $Range.End) { $Guarded = $true; break } }
            if (-not $Guarded) { $Unguarded.Add("$($File.FullName):$($i + 1): $($Line.Trim())") }
        }
    }
}
if ($Unguarded.Count -gt 0) {
    throw "Editor-only API used outside #if WITH_EDITOR:`n$($Unguarded -join "`n")"
}
Write-Output "Shipping guards OK: editor-only includes/symbols stay inside #if WITH_EDITOR"

$BuildCs = Get-Content -LiteralPath (Join-Path $Root "Source\FPS\FPS.Build.cs") -Encoding UTF8 -Raw
if ($BuildCs -notmatch 'Target\.bBuildEditor') {
    throw "FPS.Build.cs must keep DesktopPlatform behind Target.bBuildEditor"
}
# Niagara must stay removed (zero symbol references across the module).
# ApplicationCore is REQUIRED since 2026-09-18: UGCPlayerController::CopyToClipboard calls
# FPlatformApplicationMisc::ClipboardCopy at runtime; a modular editor build fails to link
# without it (a monolithic Shipping build hides the problem).
# See docs/knowledge/RISKS_AND_GAPS.md ("merge incident" section).
foreach ($Banned in @('"Niagara"')) {
    if ($BuildCs.Contains($Banned)) {
        throw "FPS.Build.cs reintroduced an unused dependency: $Banned (T19 removed it; document the new usage if it is really needed)"
    }
}
Write-Output "Dependency guards OK: DesktopPlatform is editor-only, no unused Niagara/ApplicationCore"
$RootLua = $Root -replace '\\','/'
& $LuaExe (Join-Path $PSScriptRoot "run.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_scene.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_serialization.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_registry.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_logging.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_llm_gateway.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$TestData = Join-Path $Root "Temp\UGCTestData"
New-Item -ItemType Directory -Force -Path $TestData | Out-Null
& $LuaExe (Join-Path $PSScriptRoot "run_persistence.lua") $RootLua ($TestData -replace '\\','/')
exit $LASTEXITCODE
