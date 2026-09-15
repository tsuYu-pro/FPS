// Copyright Epic Games, Inc. All Rights Reserved.

/**
 * UGCSmokeTestCommands.cpp（T3 验收工具）
 *
 * 目的：让「UE 5.4 编辑器内 PIE 验收」可以脚本化复现，而不是靠人工点鼠标。
 *
 * 为什么需要 C++ 这一层：7 项验收里有 Delay / Interval 真实时间调度、Trigger 事件链路、
 * Authoring↔Playtest 切换，只能在真实的 PIE 世界里跑；而 PIE 的启动与日志读取由编辑器
 * 侧的 MCP（UEEditorMCP，端口 55558）负责，所以这里只提供两个入口：
 *
 *   UGC.SmokeTestEnable       打开「BeginPlay 时自动跑冒烟」开关（编辑器启动参数里给）
 *   UGC.SmokeTest             立刻对当前世界（PIE 优先）触发一次冒烟
 *
 * 真正的 7 项逻辑全在 Lua：Content/Script/Gameplay/UGC/UGCSmokeTest.lua
 * （Lua 侧从 PC 的 ReceiveBeginPlay / ReceiveTick 驱动，能处理跨帧等待）。
 *
 * 用法：
 *   UnrealEditor.exe <project>.uproject -ExecCmds="UGC.SmokeTestEnable"
 *   → 编辑器内 start_pie（MCP）→ 世界 BeginPlay 自动跑 → 结果进 Saved/Logs/FPS.log
 */

#include "CoreMinimal.h"

#if WITH_EDITOR

#include "UGCPlayerController.h"
#include "Engine/World.h"
#include "Editor.h"
#include "Engine/Engine.h"
#include "HAL/IConsoleManager.h"
#include "FileHelpers.h"

namespace
{
    /** BeginPlay 时是否自动跑冒烟（默认关，避免影响日常 PIE） */
    bool GUGCSmokeTestAutoRun = false;

    UWorld* ResolveSmokeTestWorld(UWorld* CommandWorld)
    {
        // PIE 优先：验收永远针对正在跑的那个世界
        if (GEditor && GEditor->PlayWorld)
        {
            return GEditor->PlayWorld;
        }
        if (CommandWorld)
        {
            return CommandWorld;
        }
        return GEngine ? GEngine->GetWorldContexts().Num() > 0 ? GEngine->GetWorldContexts()[0].World() : nullptr : nullptr;
    }

    void TriggerSmokeTest(UWorld* World)
    {
        if (!World)
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCSmokeTest] 找不到可用的世界（先启动 PIE）"));
            return;
        }

        AUGCPlayerController* PC = Cast<AUGCPlayerController>(World->GetFirstPlayerController());
        if (!PC)
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCSmokeTest] 世界里没有 AUGCPlayerController，无法跑验收"));
            return;
        }

        UE_LOG(LogTemp, Display, TEXT("[UGCSmokeTest] 触发 7 项冒烟验收（世界 %s）"), *World->GetName());
        PC->RequestUGCSmokeTest();
    }

    /**
     * 把编辑器切到 UGC 测试关卡。
     *
     * 为什么需要它：冒烟驱动挂在 AUGCPlayerController 上，而编辑器默认打开的登录地图只有菜单 PC，
     * PIE 直接在登录地图里跑的话冒烟永远不会开始（2026-09-15 实测：PIE 起来 6 分钟没有任何 smoke_* 事件；
     * 之前那次 7/7 是先在游戏里选图开主机才进到 UGC 关卡的）。
     * 用 ULevelEditorSubsystem::LoadLevel —— 与 File > Open Level 同一条路（会处理保存提示与旧 World 释放）。
     */
    void OpenUGCLevelForSmoke()
    {
        const FString LevelPath = TEXT("/Game/_UGC/Level/UGC_Test/UGC_TestMap");
        if (!GEditor)
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCSmokeTest] GEditor 不可用，无法切换关卡"));
            return;
        }

        // UEditorLoadingAndSavingUtils::LoadMap：与 File > Open Level 同一条路，但不弹「保存当前关卡」对话框
        // （脚本化流程不会改动当前关卡，所以这里丢掉未保存改动的风险可接受）。
        // 注意：FEditorFileUtils::LoadMap 是同名的另一个重载，返回 bool，别用错。
        UWorld* Loaded = UEditorLoadingAndSavingUtils::LoadMap(LevelPath);
        if (Loaded)
        {
            UE_LOG(LogTemp, Display, TEXT("[UGCSmokeTest] 编辑器已切到 %s（PIE 会从这里复制世界）"), *LevelPath);
        }
        else
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCSmokeTest] 切换关卡失败：%s"), *LevelPath);
        }
    }

    FAutoConsoleCommandWithWorldAndArgs GUGCSmokeTestEnableCommand(
        TEXT("UGC.SmokeTestEnable"),
        TEXT("打开 UGC 冒烟验收自动运行开关：PIE BeginPlay 时自动跑 7 项（T3）"),
        FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(
            [](const TArray<FString>& Args, UWorld*)
            {
                GUGCSmokeTestAutoRun = Args.Num() == 0 || Args[0] != TEXT("0");
                UE_LOG(LogTemp, Display, TEXT("[UGCSmokeTest] 自动运行开关 = %s"),
                    GUGCSmokeTestAutoRun ? TEXT("开") : TEXT("关"));
            }));

    FAutoConsoleCommandWithWorldAndArgs GUGCSmokeTestRunCommand(
        TEXT("UGC.SmokeTest"),
        TEXT("对当前世界（PIE 优先）立刻触发 UGC 冒烟验收（T3 的 7 项 + T16 的错误列表项）"),
        FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(
            [](const TArray<FString>&, UWorld* World)
            {
                TriggerSmokeTest(ResolveSmokeTestWorld(World));
            }));

    FAutoConsoleCommand GUGCSmokeTestOpenLevelCommand(
        TEXT("UGC.SmokeTestOpenUGCLevel"),
        TEXT("把编辑器切到 /Game/_UGC/Level/UGC_Test/UGC_TestMap（冒烟必须在带 AUGCPlayerController 的世界里跑）"),
        FConsoleCommandDelegate::CreateStatic(&OpenUGCLevelForSmoke));
}

bool AUGCPlayerController::IsUGCSmokeTestEnabled() const
{
    return GUGCSmokeTestAutoRun;
}

void AUGCPlayerController::RequestUGCSmokeTest()
{
    // 交给 Lua 实现（BlueprintImplementableEvent → UnLua M:RunUGCSmokeTest）
    RunUGCSmokeTest();
}

#endif // WITH_EDITOR
