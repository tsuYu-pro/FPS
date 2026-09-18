// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;

public class FPS : ModuleRules
{
	public FPS(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = PCHUsageMode.UseExplicitOrSharedPCHs;

		PublicDependencyModuleNames.AddRange(new string[] {
			"Core",
			"CoreUObject",
			"Engine",
			"InputCore",
			"EnhancedInput",
			"UMG",
			"Slate",
			"SlateCore",
			"GameplayAbilities",
			"GameplayTags",
			"GameplayTasks",
			// FPSCharacter.h 暴露 IGenericTeamAgentInterface，该头在 AIModule
			"AIModule",
			"UnLua",
			"glTFRuntime"
		});

		// 仅模块内部 .cpp 使用：UGCHttpClient / FabClientBridge / UGCPCGBridge
		PrivateDependencyModuleNames.AddRange(new string[] {
			"HTTP",
			"Json",
			"JsonUtilities",
			"PCG",
			// UGCPlayerController::CopyToClipboard → FPlatformApplicationMisc::ClipboardCopy。
			// 模块化编辑器构建必须显式声明，否则 LNK2019（单体 Shipping 构建会掩盖该问题）。
			"ApplicationCore"
		});

		if (Target.bBuildEditor)
		{
			// 原生文件对话框等编辑器专属能力（UGCEditorBridge / AnimGenClient），
			// 只在编辑器构建链接；运行时路径必须自带 #if WITH_EDITOR 回退。
			PrivateDependencyModuleNames.Add("DesktopPlatform");
		}
	}
}
