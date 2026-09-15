// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;

public class FPS : ModuleRules
{
	public FPS(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		// Public：本模块的公开头文件会把这些模块的类型暴露出去（UUserWidget / GAS / EnhancedInput /
		// IGenericTeamAgentInterface / UnLua 接口），所以任何包含 FPS 头的模块都能看到它们。
		PublicDependencyModuleNames.AddRange(new string[] {
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore",        // UGCEditorBridge.cpp 使用 FKey；FPSCharacter.h 暴露输入相关类型
			"EnhancedInput",    // FPSCharacter.h / FPSPlayerController.h 的 UPROPERTY 暴露 UInputAction*、UInputMappingContext*
			"UMG",              // UI/FPSCrosshairWidget.h、UI/Menu/*、Inventory/Public/*Widget.h 暴露 UUserWidget
			"Slate",            // UGC/UGCWireOverlay.h、UGCEditorBridge.cpp 使用 Slate 控件与窗口
			"SlateCore",
			"GameplayAbilities", // GAS/、Weapon/FPSWeaponBase.h 暴露 UAbilitySystemComponent
			"GameplayTags",
			"GameplayTasks",
			"UnLua",            // Armor/GAS/Weapon 的公开头文件实现 IUnLuaInterface
			"AIModule",         // FPSCharacter.h 暴露 IGenericTeamAgentInterface
			"HTTP"              // UGC/UGCHttpClient.h 与 AnimAgent/Fab/FabClientBridge.h 是公开头文件，
			                    // 且都 include "Interfaces/IHttpRequest.h"，因此 HTTP 必须留在 Public。
		});

		// Private：只在 .cpp 内部使用的模块。放在这里同样是"依赖瘦身"的一部分——
		// 它们不会成为本模块公开接口的一部分，将来拆分 UGC 插件（T11）时可以整块搬走。
		PrivateDependencyModuleNames.AddRange(new string[] {
			"Json",             // UGC/UGCHttpClient.cpp、AnimAgent/AnimGen/AnimGenClient.cpp：请求/响应体构造
			"PCG",              // UGC/UGCPCGBridge.cpp：PCGComponent / PCGGraph
			"glTFRuntime",      // AnimAgent/AnimImportBridge.cpp：运行时 glb → UStaticMesh
			"ApplicationCore"   // UGC/UGCPlayerController.cpp：FPlatformApplicationMisc::ClipboardCopy
			                    // （HAL/PlatformApplicationMisc.h）。删掉会 LNK2019 —— 2026-09-14 的
			                    // UE 5.4 开发构建实测过，不要因为"看起来没引用"再次移除。
		});

		// 编辑器专用：DesktopPlatform 只在 WITH_EDITOR 的资产/文件对话框路径里出现
		// （UGC/UGCEditorBridge.cpp、AnimAgent/AnimGen/AnimGenClient.cpp 已被 #if WITH_EDITOR 包住），
		// Shipping 不链接它。
		if (Target.bBuildEditor)
		{
			PrivateDependencyModuleNames.Add("DesktopPlatform");
			// T5/T3 迁移与验收工具（UGC/UGCPrefabDevCommands.cpp、UGC/UGCSmokeTestCommands.cpp，
			// 两个文件整体都在 #if WITH_EDITOR 内）：
			//   AssetRegistry → FAssetRegistryModule::AssetCreated（让编辑器不重启也能看到新资产）
			//   UnrealEd      → GEditor（冒烟测试要拿 PIE 世界）、FKismetEditorUtilities / FBlueprintEditorUtils
			//                   （UGC/UGCWidgetSetupCommands.cpp 编译蓝图）
			//   UMGEditor     → UWidgetBlueprint / UWidgetBlueprintFactory
			//                   （UGC/UGCWidgetSetupCommands.cpp 建 WBP_UGCErrorRow 并给编辑器控件补错误面板）
			// 都是编辑器模块，Shipping 不参与，因此与 DesktopPlatform 同一原则放在 bBuildEditor 分支。
			PrivateDependencyModuleNames.AddRange(new string[]
			{
				"AssetRegistry",
				"UnrealEd",
				"UMGEditor"
			});
		}

		// 已移除：Niagara（全模块无任何符号引用）、JsonUtilities（无符号引用，JSON 类型来自 Json 模块）。
		// 若将来新增引用请重新加入对应列表。
		//
		// 注意 ApplicationCore：它看着能删（Slate/UMG 会传递它），但 UGC/UGCPlayerController.cpp
		// 直接调 FPlatformApplicationMisc::ClipboardCopy，删掉会在链接期报 LNK2019。
		// 保留它是 T19 依赖瘦身的一次实测修正，别按"看起来没引用"再删一次。
	}
}
