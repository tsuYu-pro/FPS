// Copyright Epic Games, Inc. All Rights Reserved.

using UnrealBuildTool;
using System.IO;
using System;

public class meshy : ModuleRules
{
	public meshy(ReadOnlyTargetRules Target) : base(Target)
	{
		PCHUsage = ModuleRules.PCHUsageMode.UseExplicitOrSharedPCHs;
		
		// 版本兼容性宏 - 支持 UE 5.4 / 5.6 / 5.7
		// 使用 ENGINE_MAJOR_VERSION 和 ENGINE_MINOR_VERSION 进行条件编译
		// 这些宏在引擎中已经定义，可以直接在 C++ 代码中使用

		// 引擎模块目录会随版本挪位置（5.4：AssetTools 与 ToolMenus 都在 Developer/ 下；更新的版本里
		// 有的搬到了 Runtime/ 或 Editor/）。这里按实际存在的目录解析，避免把版本表写死——
		// 写死一条就会在另一版本上产生 "Referenced directory ... does not exist" 警告。
		string EngineSourceDir = Path.Combine(EngineDirectory, "Source");
		string AssetToolsDir = Directory.Exists(Path.Combine(EngineSourceDir, "Runtime/AssetTools"))
			? "Runtime/AssetTools" : "Developer/AssetTools";
		string ToolMenusDir = Directory.Exists(Path.Combine(EngineSourceDir, "Editor/ToolMenus"))
			? "Editor/ToolMenus" : "Developer/ToolMenus";
		string AssetToolsPublic = AssetToolsDir + "/Public";

		PublicIncludePaths.AddRange(
			new string[] {
				"Runtime/Core/Public",
				"Runtime/CoreUObject/Public",
				"Runtime/Engine/Classes",
				"Runtime/Slate/Public",
				"Runtime/SlateCore/Public",
				"Runtime/AssetRegistry/Public",
				AssetToolsPublic,
				"Runtime/Json/Public",
				"Runtime/JsonUtilities/Public",
				"Runtime/Networking/Public",
				"Runtime/Sockets/Public"
			}
		);
				
		
		// 下面是引擎目录下的模块头文件路径：写成相对路径时 UBT 会按“插件相对目录”解析，
		// 于是每条都报 "Referenced directory ... does not exist"。必须用引擎根目录拼绝对路径。
		PrivateIncludePaths.AddRange(
			new string[] {
				Path.Combine(EngineSourceDir, "Editor/UnrealEd/Public"),
				Path.Combine(EngineSourceDir, "Editor/UnrealEd/Private"),
				Path.Combine(EngineSourceDir, "Editor/EditorStyle/Public"),
				Path.Combine(EngineSourceDir, "Editor/LevelEditor/Public"),
				Path.Combine(EngineSourceDir, "Editor/LevelEditor/Private"),
				Path.Combine(EngineSourceDir, ToolMenusDir + "/Public"),
				Path.Combine(EngineSourceDir, ToolMenusDir + "/Private")
			}
		);
			
		
		PublicDependencyModuleNames.AddRange(
			new string[]
			{
				"Core",
				"Projects",
				"Json",
				"Sockets",
				"Networking",
				"HTTP",
				"PakFile",
				// UE 5.4 兼容性改动：删 zlib，改用 FileUtilities 模块的 FZipArchiveReader 解压 zip
				"FileUtilities",
                // 添加UI相关模块
                "SlateCore",
                "Slate",
                "UMG"
			}
		);
			
		
		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"CoreUObject",
				"Engine",
				"Slate",
				"SlateCore",
				"InputCore",
				"UnrealEd",
				"AssetTools",
				"AssetRegistry",
				"LevelEditor",
				"EditorStyle",
				"ToolMenus", 
                "ApplicationCore" // 添加ApplicationCore以支持Slate UI相关功能
			}
		);

		// 添加插件依赖
		PrivateDependencyModuleNames.AddRange(
			new string[]
			{
				"UnrealEd",
				"AssetTools"
			}
		);

		// UE 5.4 兼容性：原 ConfigureMinizipSupport(Target) 已删除
		// UE 5.4 ThirdParty/zlib/1.3 没带 minizip（5.6+ 才有），改用 UE 自带的
		// FZipArchiveReader（FileUtilities 模块），编辑器构建可用，逻辑等价。
	}
}
