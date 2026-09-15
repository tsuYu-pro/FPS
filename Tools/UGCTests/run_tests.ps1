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

# --- Static guards (T17 JSON codec convergence) --------------------------------
# Util\json.lua is the only codec. rapidjson may still be mentioned in comments
# (the migration note in BP_WeaponBase.lua), so comment lines are ignored.
$ScriptOnly = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script") -Recurse -File -Filter *.lua
$RapidjsonUsages = Select-String -LiteralPath $ScriptOnly.FullName -Pattern 'rapidjson' -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch '^\s*--' }
if ($RapidjsonUsages) {
    $Detail = ($RapidjsonUsages | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
    throw "T17 keeps Util\json.lua as the single codec; rapidjson is still used under Content\Script:`n$Detail"
}
Write-Output "Codec guards OK: no rapidjson usage under Content\Script (Util\json.lua is the single codec)"

# --- Static guards (T5 prefab definitions) ------------------------------------
# UGCPlaceableConfig.lua is a MIGRATION FALLBACK only: the authoritative source is
# AssetManager (UUGCPrefabDefinition, PrimaryAssetType "UGCPrefab"). Any other Lua
# file requiring the legacy catalog means a lookup path was not migrated.
$LegacyCatalogRefs = $ScanFiles | Where-Object { $_.FullName -notmatch 'UGCPrefabRegistry|run_prefab_definitions' } |
    Select-String -Pattern 'UGCPlaceableConfig' -ErrorAction SilentlyContinue |
    Where-Object { $_.Line -notmatch '^\s*--' }
if ($LegacyCatalogRefs) {
    $Detail = ($LegacyCatalogRefs | ForEach-Object { "$($_.Path):$($_.LineNumber): $($_.Line.Trim())" }) -join "`n"
    throw "Only UGCPrefabRegistry may reference the legacy catalog (T5):`n$Detail"
}
# The bridge API the registry depends on must exist in C++ (guards against a Lua-only rename).
$BridgeHeader = Get-Content -LiteralPath (Join-Path $Root "Source\FPS\UGC\UGCEditorBridge.h") -Raw
foreach ($Api in @('GetPrefabDefinitionsJson', 'RegisterRuntimePrefabDefinition')) {
    if ($BridgeHeader -notmatch $Api) { throw "UGCEditorBridge.h is missing $Api (T5)" }
}
$PrefabCatalog = Get-Content -LiteralPath (Join-Path $Root "Source\FPS\UGC\UGCPrefabCatalog.cpp") -Raw
if ($PrefabCatalog -notmatch 'AddDynamicAsset') {
    throw "UGCPrefabCatalog.cpp must register runtime prefabs via UAssetManager::AddDynamicAsset (T5)"
}
if ($PrefabCatalog -notmatch 'UGCPrefab') {
    throw "UGCPrefabCatalog.cpp must use the UGCPrefab primary asset type (T5)"
}
Write-Output "Prefab guards OK: legacy catalog is fallback-only, definition API present, runtime prefabs use AddDynamicAsset"

# --- Static guards (module table used as a bare global) -----------------------
# A Lua file that calls UGCLog.* without requiring it will throw at runtime
# ("attempt to index a nil value (global 'UGCLog')"), which aborted RegisterAll and
# killed the whole LLM tool registry (found by the 2026-09-15 in-editor run).
# Comment lines are ignored so historical notes stay allowed.
$BareLogGlobal = Get-ChildItem -LiteralPath (Join-Path $Root "Content\Script") -Recurse -File -Filter *.lua |
    Where-Object {
        $content = Get-Content -LiteralPath $_.FullName -Raw
        ($content -match '(?<![\w:\.])UGCLog\.') -and ($content -notmatch 'require\("Gameplay\.UGC\.UGCLog"\)')
    }
if ($BareLogGlobal) {
    $Names = ($BareLogGlobal | ForEach-Object { $_.FullName }) -join "`n"
    throw "These Lua files use UGCLog without requiring it:`n$Names"
}
Write-Output "Module global guards OK: no Lua file uses UGCLog without requiring it"

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
$EditorOnlySymbols = 'FDesktopPlatformModule|FPropertyEditorModule|FLevelEditorModule|IDetailLayoutBuilder|\bGEditor\b'
# NOTE: the left \b matters - without it "GEditor" also matches inside "UMGEditor",
# which is a legitimate editor-only Build.cs dependency (FPS.Build.cs bBuildEditor block).

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
foreach ($Banned in @('"Niagara"')) {
    if ($BuildCs.Contains($Banned)) {
        throw "FPS.Build.cs reintroduced an unused dependency: $Banned (T19 removed it; document the new usage if it is really needed)"
    }
}
# ApplicationCore is a verified real dependency: UGC/UGCPlayerController.cpp calls
# FPlatformApplicationMisc::ClipboardCopy (HAL/PlatformApplicationMisc.h). Removing it made the
# 2026-09-14 UE 5.4 development build fail with LNK2019 (1 unresolved external symbol), so this
# guard now requires it instead of banning it as dead weight.
# NOTE: keep this script pure ASCII - PowerShell 5.1 decodes BOM-less files as ANSI, so non-ASCII
# comments/literals here break parsing (this file is read by the plain `powershell` host).
if (-not $BuildCs.Contains('"ApplicationCore"')) {
    throw "FPS.Build.cs must keep ApplicationCore: UGC/UGCPlayerController.cpp uses FPlatformApplicationMisc::ClipboardCopy (verified by a UE 5.4 link)"
}
Write-Output "Dependency guards OK: DesktopPlatform is editor-only, Niagara stays removed, ApplicationCore kept for ClipboardCopy"

# --- Static guards (T16 error list UI) ----------------------------------------
# The error panel and its row widget are editor-made UMG assets. If either asset
# or the Lua wiring disappears, validation silently goes back to "first error
# only" - the exact bug T16 fixes - and no runtime test would notice.
$EditorWidgetLua = Join-Path $Root "Content\Script\System\UI\UGC\WBP_UGCBlueprintEditor.lua"
$EditorWidgetSource = Get-Content -LiteralPath $EditorWidgetLua -Raw
foreach ($Needle in @('w_scroll_errors', 'w_error_panel', 'WBP_UGCErrorRow.WBP_UGCErrorRow_C', 'function M:FocusError(row)')) {
    if (-not $EditorWidgetSource.Contains($Needle)) {
        throw "WBP_UGCBlueprintEditor.lua lost the T16 error-list wiring: $Needle"
    }
}
$RowAssetPath = Join-Path $Root "Content\_UGC\UI\WBP_UGCErrorRow.uasset"
if (-not (Test-Path -LiteralPath $RowAssetPath)) {
    throw "WBP_UGCErrorRow.uasset is missing (run UGC.SetupErrorListUI in the editor; T16)"
}
$Latin1 = [System.Text.Encoding]::GetEncoding(28591)
$EditorAssetText = $Latin1.GetString([System.IO.File]::ReadAllBytes((Join-Path $Root "Content\_UGC\UI\WBP_UGCBlueprintEditor.uasset")))
foreach ($WidgetName in @('w_error_panel', 'w_error_border_bg', 'w_scroll_errors')) {
    if (-not $EditorAssetText.Contains($WidgetName)) {
        throw "WBP_UGCBlueprintEditor.uasset is missing widget $WidgetName (run UGC.SetupErrorListUI; T16)"
    }
}
Write-Output "Error-list guards OK: panel widgets present in the asset, row asset exists, Lua wires ShowErrors/FocusError"

$RootLua = $Root -replace '\\','/'
& $LuaExe (Join-Path $PSScriptRoot "run.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_scene.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_serialization.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_golden.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_weapon_ballistics.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_entity_id.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_properties.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_viewmodel.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_registry.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_prefab_definitions.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_logging.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_llm_gateway.lua") $RootLua
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
$TestData = Join-Path $Root "Temp\UGCTestData"
New-Item -ItemType Directory -Force -Path $TestData | Out-Null
& $LuaExe (Join-Path $PSScriptRoot "run_persistence.lua") $RootLua ($TestData -replace '\\','/')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_migration.lua") $RootLua ($TestData -replace '\\','/')
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
& $LuaExe (Join-Path $PSScriptRoot "run_error_list.lua") $RootLua
exit $LASTEXITCODE
