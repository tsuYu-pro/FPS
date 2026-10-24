// Copyright Epic Games, Inc. All Rights Reserved.

/**
 * FPSAttachmentTestCommands.cpp
 *
 * 「配件基类」验收用的控制台命令（v1：能力授予/撤销链路跑通）。
 *
 *   FPS.AttachmentTest [武器类路径]       对当前 PIE 世界玩家的武器立刻跑一次
 *   FPS.AttachmentTestAuto [武器类路径]   挂自动开关：PIE 世界 BeginPlay、玩家就位后自动跑一次
 *
 * 测试内容：代码构造一个临时测试配件（零资产）→ 装到武器 → 检查持有者 ASC 上
 * UGA_AttachmentTest 的授予数 +1 → 卸下 → 检查回到原值。
 * 结果写日志：逐项结构化事件 + `event=attachment_test_summary result=PASS|FAIL` 汇总行。
 *
 * 找不到武器时可传入武器类路径（如 /Game/_FPS/Weapon/KA47/BP_Weapon_KA47.BP_Weapon_KA47_C），
 * 命令会把该武器生成到玩家的 Primary1 槽（仅供自动化验收；正常游玩不需要传）。
 */

#include "CoreMinimal.h"

#if WITH_EDITOR

#include "AbilitySystemComponent.h"
#include "Containers/Ticker.h"
#include "Editor.h"
#include "Engine/Engine.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "HAL/IConsoleManager.h"
#include "UObject/UObjectGlobals.h"

#include "FPS/FPSCharacter.h"
#include "FPS/GAS/Abilities/GA_AttachmentTest.h"
#include "FPS/Weapon/FPSWeaponAttachmentData.h"
#include "FPS/Weapon/FPSWeaponBase.h"
#include "FPS/Weapon/FPSAttachmentService.h"
#include "FPS/Weapon/FPSWeaponDataAsset.h"
#include "FPS/Weapon/FPSWeaponSlotComponent.h"

namespace
{
    /** 自动运行开关（进程级；PIE 世界重建后仍有效） */
    bool GAttachmentTestAutoRun = false;
    FString GAttachmentTestAutoWeaponPath;
    FTSTicker::FDelegateHandle GAttachmentTestTickerHandle;

    UWorld* ResolveAttachmentTestWorld(UWorld* CommandWorld)
    {
        // PIE 优先：验收永远针对正在跑的那个世界
        if (GEditor && GEditor->PlayWorld)
        {
            return GEditor->PlayWorld;
        }
        return CommandWorld;
    }

    /** 统计 ASC 上属于测试能力（含子类）的授予数 */
    int32 CountAttachmentTestSpecs(UAbilitySystemComponent* ASC)
    {
        int32 Count = 0;
        if (!ASC)
        {
            return Count;
        }
        for (const FGameplayAbilitySpec& Spec : ASC->GetActivatableAbilities())
        {
            if (Spec.Ability && Spec.Ability->GetClass()->IsChildOf(UGA_AttachmentTest::StaticClass()))
            {
                ++Count;
            }
        }
        return Count;
    }

    /** 按固定偏好挑一个武器支持且当前为空的配件槽；都被占用时取第一个支持的 */
    EFPSAttachmentSlotType PickAttachmentTestSlot(const AFPSWeaponBase* Weapon)
    {
        static const EFPSAttachmentSlotType Preference[] = {
            EFPSAttachmentSlotType::Muzzle,
            EFPSAttachmentSlotType::Sight,
            EFPSAttachmentSlotType::Handguard,
            EFPSAttachmentSlotType::Magazine
        };

        const UFPSWeaponDataAsset* Data = Weapon ? Weapon->WeaponData : nullptr;
        if (!Data)
        {
            return EFPSAttachmentSlotType::None;
        }

        auto IsInstalled = [Weapon](EFPSAttachmentSlotType Slot)
        {
            for (const FFPSInstalledAttachment& Entry : Weapon->InstalledAttachmentIDs)
            {
                if (Entry.Slot == Slot)
                {
                    return true;
                }
            }
            return false;
        };

        EFPSAttachmentSlotType FirstSupported = EFPSAttachmentSlotType::None;
        for (const EFPSAttachmentSlotType Slot : Preference)
        {
            if (!Data->SupportedAttachmentSlots.Contains(Slot))
            {
                continue;
            }
            if (FirstSupported == EFPSAttachmentSlotType::None)
            {
                FirstSupported = Slot;
            }
            if (!IsInstalled(Slot))
            {
                return Slot;
            }
        }
        return FirstSupported;
    }

    /** 在玩家身上找一把可用武器；找不到且给了类路径时生成一把调试武器 */
    AFPSWeaponBase* FindAttachmentTestWeapon(UFPSWeaponSlotComponent* SlotComp, const FString& WeaponClassPath)
    {
        if (!SlotComp)
        {
            return nullptr;
        }

        if (AFPSWeaponBase* Weapon = SlotComp->GetActiveWeapon())
        {
            return Weapon;
        }

        static const EFPSWeaponSlot Slots[] = { EFPSWeaponSlot::Primary1, EFPSWeaponSlot::Primary2, EFPSWeaponSlot::Pistol };
        for (const EFPSWeaponSlot Slot : Slots)
        {
            if (AFPSWeaponBase* Weapon = SlotComp->GetWeaponInSlot(Slot))
            {
                return Weapon;
            }
        }

        if (WeaponClassPath.IsEmpty())
        {
            return nullptr;
        }

        // 调试路径：按给定类生成武器放进 Primary1（只在自动化验收里用；正式游玩不经过这里）
        TSubclassOf<AFPSWeaponBase> WeaponClass = LoadClass<AFPSWeaponBase>(nullptr, *WeaponClassPath);
        if (!WeaponClass)
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 武器类加载失败：%s"), *WeaponClassPath);
            return nullptr;
        }

        FInventoryItem DebugItem;
        DebugItem.ItemDefID = TEXT("DebugTestWeapon");
        if (!SlotComp->SetWeaponInSlot(EFPSWeaponSlot::Primary1, DebugItem, WeaponClass))
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 调试武器生成失败（Primary1 槽）"));
            return nullptr;
        }

        UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] 已生成调试武器 %s 到 Primary1"), *WeaponClassPath);
        return SlotComp->GetWeaponInSlot(EFPSWeaponSlot::Primary1);
    }

    void RunAttachmentTest(UWorld* World, const FString& WeaponClassPath)
    {
        if (!World)
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 找不到世界（先在编辑器里启动 PIE）"));
            return;
        }

        AFPSCharacter* Character = nullptr;
        if (APlayerController* PC = World->GetFirstPlayerController())
        {
            Character = Cast<AFPSCharacter>(PC->GetPawn());
        }
        if (!Character)
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 当前世界没有 AFPSCharacter 玩家（先启动 PIE 并进入游戏）"));
            return;
        }

        UFPSWeaponSlotComponent* SlotComp = Character->FindComponentByClass<UFPSWeaponSlotComponent>();
        AFPSWeaponBase* Weapon = FindAttachmentTestWeapon(SlotComp, WeaponClassPath);
        if (!Weapon)
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 玩家身上没有武器（先装备一把，或用参数传武器类路径）"));
            return;
        }

        const EFPSAttachmentSlotType TestSlot = PickAttachmentTestSlot(Weapon);
        if (TestSlot == EFPSAttachmentSlotType::None)
        {
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 武器 %s 没有可用的配件槽（检查 WeaponData.SupportedAttachmentSlots）"), *Weapon->GetName());
            return;
        }

        UAbilitySystemComponent* ASC = Character->GetAbilitySystemComponent();
        const int32 BeforeCount = CountAttachmentTestSpecs(ASC);

        // 代码构造临时测试配件：零资产、零内容依赖
        UFPSWeaponAttachmentData* TestAtt = NewObject<UFPSWeaponAttachmentData>(GetTransientPackage());
        TestAtt->AttachmentID = TEXT("DebugTestAttachment");
        TestAtt->SlotType = TestSlot;
        TestAtt->GrantedAbilities.Add(TSubclassOf<UFPSGameplayAbility>(UGA_AttachmentTest::StaticClass()));

        UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] ===== 开始：武器 %s / 槽 %d / ASC 测试能力数 %d ====="),
            *Weapon->GetName(), static_cast<int32>(TestSlot), BeforeCount);

        const bool bInstalled = UFPSAttachmentService::InstallAttachment(Weapon, TestSlot, TestAtt);
        const int32 AfterInstallCount = CountAttachmentTestSpecs(ASC);
        UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] event=attachment_test_install ok=%s count=%d expected=%d"),
            bInstalled ? TEXT("true") : TEXT("false"), AfterInstallCount, BeforeCount + 1);

        UFPSWeaponAttachmentData* Removed = nullptr;
        const bool bRemoved = UFPSAttachmentService::RemoveAttachment(Weapon, TestSlot, Removed);
        const int32 AfterRemoveCount = CountAttachmentTestSpecs(ASC);
        UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] event=attachment_test_remove ok=%s count=%d expected=%d"),
            bRemoved ? TEXT("true") : TEXT("false"), AfterRemoveCount, BeforeCount);

        const bool bPass = bInstalled && bRemoved
            && AfterInstallCount == BeforeCount + 1
            && AfterRemoveCount == BeforeCount;
        UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] event=attachment_test_summary result=%s before=%d after_install=%d after_remove=%d"),
            bPass ? TEXT("PASS") : TEXT("FAIL"), BeforeCount, AfterInstallCount, AfterRemoveCount);
    }

    /** 自动运行：等 PIE 世界 BeginPlay 且玩家就位后跑一次（每 1 秒轮询；最多等 120 秒） */
    bool TickAttachmentTestAuto(float)
    {
        if (!GAttachmentTestAutoRun)
        {
            return false; // 开关被关：移除轮询
        }

        UWorld* PIE = GEditor ? GEditor->PlayWorld : nullptr;
        if (PIE && PIE->HasBegunPlay())
        {
            if (APlayerController* PC = PIE->GetFirstPlayerController())
            {
                if (Cast<AFPSCharacter>(PC->GetPawn()))
                {
                    GAttachmentTestAutoRun = false;
                    RunAttachmentTest(PIE, GAttachmentTestAutoWeaponPath);
                    return false;
                }
            }
        }

        static int32 WaitedTicks = 0;
        if (++WaitedTicks > 120)
        {
            GAttachmentTestAutoRun = false;
            UE_LOG(LogTemp, Warning, TEXT("[AttachmentTest] 自动运行超时：等不到可用的 PIE 玩家（120 秒）"));
            return false;
        }
        return true;
    }

    FAutoConsoleCommandWithWorldAndArgs GFPSAttachmentTestCommand(
        TEXT("FPS.AttachmentTest"),
        TEXT("配件基类验收：给当前 PIE 玩家的武器装/卸一个临时测试配件，检查 ASC 技能表 +1/-1（可选参数：武器类路径）"),
        FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(
            [](const TArray<FString>& Args, UWorld* World)
            {
                RunAttachmentTest(ResolveAttachmentTestWorld(World), Args.Num() > 0 ? Args[0] : FString());
            }));

    FAutoConsoleCommandWithWorldAndArgs GFPSAttachmentTestAutoCommand(
        TEXT("FPS.AttachmentTestAuto"),
        TEXT("挂自动开关：PIE 世界 BeginPlay 且玩家就位后自动跑一次 FPS.AttachmentTest（编辑器启动参数里给）"),
        FConsoleCommandWithWorldAndArgsDelegate::CreateStatic(
            [](const TArray<FString>& Args, UWorld*)
            {
                GAttachmentTestAutoWeaponPath = Args.Num() > 0 ? Args[0] : FString();
                GAttachmentTestAutoRun = true;
                if (!GAttachmentTestTickerHandle.IsValid())
                {
                    GAttachmentTestTickerHandle = FTSTicker::GetCoreTicker().AddTicker(
                        FTickerDelegate::CreateStatic(&TickAttachmentTestAuto), 1.0f);
                }
                UE_LOG(LogTemp, Display, TEXT("[AttachmentTest] 自动运行开关 = 开（武器路径：%s）"),
                    GAttachmentTestAutoWeaponPath.IsEmpty() ? TEXT("(用玩家已有武器)") : *GAttachmentTestAutoWeaponPath);
            }));
}

#endif // WITH_EDITOR
