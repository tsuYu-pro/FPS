// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "UObject/StrongObjectPtr.h"
#include "UGCPrefabDefinition.h"

/**
 * FUGCPrefabCatalog —— 预制体目录（T5）
 *
 * 唯一职责：把「AssetManager 扫描到的 UUGCPrefabDefinition」与「运行时动态注册的定义」
 * 合成一份列表，并提供两件事给上层：
 *   1. Lua / LLM / UI 用的扁平列表（JSON 字符串，避免 TArray<USTRUCT> 跨语言编组的歧义）
 *   2. SpawnPlaceable 的类路径白名单（被定义引用 or 历史 Gizmo 路径 or 动态占位类）
 *
 * 运行时注册走 UAssetManager::AddDynamicAsset，因此磁盘资产与运行时导入资产
 * 共用同一个 PrimaryAssetType("UGCPrefab") 的 ID 空间。
 */
class FPS_API FUGCPrefabCatalog
{
public:
    /** 全部定义：AssetManager 里的（Source="asset"）+ 运行时注册的（Source="dynamic"），按 Id 排序 */
    static TArray<FUGCPlaceableInfo> GetDefinitions();

    /** 定义列表 → JSON 数组字符串（字段与 Lua 侧 UGCPrefabRegistry 的解析逐字段对应） */
    static FString DefinitionsToJson(const TArray<FUGCPlaceableInfo>& Definitions);

    /**
     * 该类路径是否允许 Spawn。
     * 允许的三类：① 被某个 Definition 引用 ② 历史 Placeable / Gizmo 目录 ③ 动态占位类
     */
    static bool IsClassPathAllowed(const FString& ClassPath);

    /**
     * 运行时注册一个定义（GLB / runtime package）。
     * 生成 transient 的 UUGCPrefabDefinition 并 AddDynamicAsset 到 "UGCPrefab" 类型下。
     * @param KindName  "blueprint" | "runtime_asset" | "dynamic_glb"（也接受 UE 枚举名）
     */
    static bool RegisterRuntimeDefinition(const FString& KindName, const FString& Id, const FString& ClassPath,
        const FString& Label, const FString& Category, const FString& Description, const TArray<FString>& Tags);

    /** 清空运行时注册（关卡切换 / 回归测试用） */
    static void ResetRuntimeDefinitions();

    /** 运行时注册数量（诊断用） */
    static int32 GetRuntimeDefinitionCount();

    /** 枚举 ↔ Lua 字符串（"blueprint" / "runtime_asset" / "dynamic_glb"） */
    static FString KindToString(EUGCPrefabKind Kind);
    static EUGCPrefabKind KindFromString(const FString& KindName);

private:
    /**
     * Id → transient definition（运行时注册的定义，不落盘）。
     *
     * 用 TStrongObjectPtr 而不是裸 TObjectPtr：这是**静态**容器，不受 UPROPERTY 的引用跟踪，
     * 存裸指针的话下次 GC 会把这些 NewObject(RF_Transient) 定义回收掉，
     * 之后 GetDefinitions() 遍历到这里就是悬垂指针 —— 2026-09-15 PIE 实测直接
     * EXCEPTION_ACCESS_VIOLATION（崩在 UUGCPrefabDefinition::ToPlaceableInfo）。
     */
    static TMap<FName, TStrongObjectPtr<UUGCPrefabDefinition>> RuntimeDefinitions;

    static bool InfoFromDefinition(const UUGCPrefabDefinition* Definition, const FString& Source, FUGCPlaceableInfo& OutInfo);
};
