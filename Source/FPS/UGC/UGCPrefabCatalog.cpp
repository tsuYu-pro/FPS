// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCPrefabCatalog.h"
#include "Engine/AssetManager.h"
#include "GameFramework/Actor.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#include "Policies/CondensedJsonPrintPolicy.h"
#include "UObject/UObjectGlobals.h"

TMap<FName, TStrongObjectPtr<UUGCPrefabDefinition>> FUGCPrefabCatalog::RuntimeDefinitions;

namespace
{
    /** 历史路径：迁移期还没有 Definition 的 Placeable / Gizmo 资产 */
    const TCHAR* const LegacyClassPathPrefixes[] =
    {
        TEXT("/Game/_UGC/Placeables/"),
        TEXT("/Game/_UGC/Editor/Actor/"),
    };

    /** 动态占位类：runtime package / GLB 都生成这个 native 宿主，spawn 后由 EditorCore 注入 mesh */
    const TCHAR* const DynamicPlaceableClassPath = TEXT("/Script/FPS.AnimAgentDynamicPlaceable");
}

bool FUGCPrefabCatalog::InfoFromDefinition(const UUGCPrefabDefinition* Definition, const FString& Source, FUGCPlaceableInfo& OutInfo)
{
    if (!Definition)
    {
        return false;
    }
    Definition->ToPlaceableInfo(OutInfo, Source);
    // 没有类路径的定义无法放置，直接跳过（也避免把脏数据喂给 Lua）
    return !OutInfo.ClassPath.IsEmpty();
}

TArray<FUGCPlaceableInfo> FUGCPrefabCatalog::GetDefinitions()
{
    TArray<FUGCPlaceableInfo> Result;

    // ① AssetManager 扫描到的磁盘资产
    UAssetManager& Manager = UAssetManager::Get();
    TArray<FPrimaryAssetId> Ids;
    Manager.GetPrimaryAssetIdList(UUGCPrefabDefinition::PrefabAssetType, Ids);
    for (const FPrimaryAssetId& Id : Ids)
    {
        // 注意：GetPrimaryAssetObject 只在"已经在内存里"时才返回对象（不是惰性加载），
        // 定义资产平时并不常驻内存，所以这里用 GetPrimaryAssetPath(...).TryLoad()。
        // 2026-09-15 首次 PIE 实测：只用 GetPrimaryAssetObject 会拿到 nullptr，
        // 注册表就静默退回旧 Catalog（definitions=0）。
        UUGCPrefabDefinition* Definition = Manager.GetPrimaryAssetObject<UUGCPrefabDefinition>(Id);
        if (!Definition)
        {
            const FSoftObjectPath DefinitionPath = Manager.GetPrimaryAssetPath(Id);
            Definition = Cast<UUGCPrefabDefinition>(DefinitionPath.TryLoad());
        }
        FUGCPlaceableInfo Info;
        if (InfoFromDefinition(Definition, TEXT("asset"), Info))
        {
            Result.Add(MoveTemp(Info));
        }
        else if (!Definition)
        {
            UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabCatalog] PrimaryAssetId %s 解析不到 UUGCPrefabDefinition"), *Id.ToString());
        }
    }

    // ② 运行时注册的（GLB / runtime package）
    for (const TPair<FName, TStrongObjectPtr<UUGCPrefabDefinition>>& Pair : RuntimeDefinitions)
    {
        FUGCPlaceableInfo Info;
        if (InfoFromDefinition(Pair.Value.Get(), TEXT("dynamic"), Info))
        {
            Result.Add(MoveTemp(Info));
        }
    }

    Result.Sort([](const FUGCPlaceableInfo& A, const FUGCPlaceableInfo& B)
    {
        return A.Id.LexicalLess(B.Id);
    });
    return Result;
}

bool FUGCPrefabCatalog::IsClassPathAllowed(const FString& ClassPath)
{
    if (ClassPath.IsEmpty())
    {
        return false;
    }

    // ① 被某个 Definition 引用（磁盘定义 or 运行时注册）
    for (const FUGCPlaceableInfo& Info : GetDefinitions())
    {
        if (Info.ClassPath.Equals(ClassPath, ESearchCase::IgnoreCase))
        {
            return true;
        }
    }

    // ② 动态占位类（GLB / runtime package 的实际承载者）
    if (ClassPath.Equals(DynamicPlaceableClassPath, ESearchCase::IgnoreCase))
    {
        return true;
    }

    // ③ 历史路径（迁移期：还没有 Definition 的资产仍可放置）
    for (const TCHAR* Prefix : LegacyClassPathPrefixes)
    {
        if (ClassPath.StartsWith(Prefix))
        {
            return true;
        }
    }
    return false;
}

FString FUGCPrefabCatalog::KindToString(EUGCPrefabKind Kind)
{
    switch (Kind)
    {
    case EUGCPrefabKind::RuntimeAsset: return TEXT("runtime_asset");
    case EUGCPrefabKind::DynamicGLB:   return TEXT("dynamic_glb");
    case EUGCPrefabKind::Blueprint:
    default:                           return TEXT("blueprint");
    }
}

EUGCPrefabKind FUGCPrefabCatalog::KindFromString(const FString& KindName)
{
    // 兼容 Lua 侧 snake_case 与 UE 枚举名两种写法
    if (KindName.Equals(TEXT("runtime_asset"), ESearchCase::IgnoreCase)
        || KindName.Equals(TEXT("RuntimeAsset"), ESearchCase::IgnoreCase))
    {
        return EUGCPrefabKind::RuntimeAsset;
    }
    if (KindName.Equals(TEXT("dynamic_glb"), ESearchCase::IgnoreCase)
        || KindName.Equals(TEXT("DynamicGLB"), ESearchCase::IgnoreCase)
        || KindName.Equals(TEXT("DynamicGlb"), ESearchCase::IgnoreCase))
    {
        return EUGCPrefabKind::DynamicGLB;
    }
    return EUGCPrefabKind::Blueprint;
}

bool FUGCPrefabCatalog::RegisterRuntimeDefinition(const FString& KindName, const FString& Id, const FString& ClassPath,
    const FString& Label, const FString& Category, const FString& Description, const TArray<FString>& Tags)
{
    if (Id.IsEmpty() || ClassPath.IsEmpty())
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabCatalog] RegisterRuntimeDefinition 缺 Id 或 ClassPath"));
        return false;
    }

    const FName PrefabName(*Id);
    TStrongObjectPtr<UUGCPrefabDefinition>* Existing = RuntimeDefinitions.Find(PrefabName);
    UUGCPrefabDefinition* Definition = Existing ? Existing->Get() : nullptr;
    if (!Definition)
    {
        Definition = NewObject<UUGCPrefabDefinition>(GetTransientPackage(), NAME_None, RF_Transient);
        RuntimeDefinitions.Add(PrefabName, TStrongObjectPtr<UUGCPrefabDefinition>(Definition));
    }

    Definition->PrefabId    = PrefabName;
    Definition->DisplayName = FText::FromString(Label.IsEmpty() ? Id : Label);
    Definition->Category    = FName(*Category);
    Definition->Description = Description;
    Definition->Kind        = KindFromString(KindName);
    Definition->Tags.Reset();
    for (const FString& Tag : Tags)
    {
        Definition->Tags.Add(FName(*Tag));
    }
    Definition->ActorClass = TSoftClassPtr<AActor>(FSoftObjectPath(*ClassPath));

    // 进 AssetManager 的 ID 空间。
    // 注意：必须用「不参与磁盘扫描」的 RuntimePrefabAssetType —— AddDynamicAsset 内部
    // ensure(TypeData.Info.bIsDynamicAsset)，而被扫描过的类型这条是 false（引擎不允许
    // 一个类型既扫描又 dynamic）。2026-09-15 首次 PIE 实测踩到过这个 ensure。
    UAssetManager& Manager = UAssetManager::Get();
    const FPrimaryAssetId PrimaryAssetId(UUGCPrefabDefinition::RuntimePrefabAssetType, PrefabName);
    FAssetBundleData EmptyBundles;
    const bool bRegistered = Manager.AddDynamicAsset(PrimaryAssetId, FSoftObjectPath(), EmptyBundles);
    if (!bRegistered)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCPrefabCatalog] AddDynamicAsset 失败：%s"), *PrimaryAssetId.ToString());
    }
    return bRegistered;
}

void FUGCPrefabCatalog::ResetRuntimeDefinitions()
{
    RuntimeDefinitions.Reset();
}

int32 FUGCPrefabCatalog::GetRuntimeDefinitionCount()
{
    return RuntimeDefinitions.Num();
}

FString FUGCPrefabCatalog::DefinitionsToJson(const TArray<FUGCPlaceableInfo>& Definitions)
{
    TArray<TSharedPtr<FJsonValue>> Items;
    for (const FUGCPlaceableInfo& Info : Definitions)
    {
        const TSharedRef<FJsonObject> Object = MakeShared<FJsonObject>();
        Object->SetStringField(TEXT("id"), Info.Id.ToString());
        Object->SetStringField(TEXT("classPath"), Info.ClassPath);
        Object->SetStringField(TEXT("label"), Info.Label);
        Object->SetStringField(TEXT("category"), Info.Category);
        Object->SetStringField(TEXT("description"), Info.Description);
        Object->SetNumberField(TEXT("version"), Info.Version);
        Object->SetNumberField(TEXT("cost"), Info.Cost);
        Object->SetStringField(TEXT("kind"), KindToString(Info.Kind));
        Object->SetStringField(TEXT("source"), Info.Source);

        TArray<TSharedPtr<FJsonValue>> Tags;
        for (const FString& Tag : Info.Tags)
        {
            Tags.Add(MakeShared<FJsonValueString>(Tag));
        }
        Object->SetArrayField(TEXT("tags"), Tags);

        TArray<TSharedPtr<FJsonValue>> Modes;
        for (const FString& Mode : Info.AllowedModes)
        {
            Modes.Add(MakeShared<FJsonValueString>(Mode));
        }
        Object->SetArrayField(TEXT("allowedModes"), Modes);

        TArray<TSharedPtr<FJsonValue>> Bounds;
        Bounds.Add(MakeShared<FJsonValueNumber>(Info.Bounds.X));
        Bounds.Add(MakeShared<FJsonValueNumber>(Info.Bounds.Y));
        Bounds.Add(MakeShared<FJsonValueNumber>(Info.Bounds.Z));
        Object->SetArrayField(TEXT("bounds"), Bounds);

        Items.Add(MakeShared<FJsonValueObject>(Object));
    }

    FString Output;
    const TSharedRef<TJsonWriter<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>> Writer =
        TJsonWriterFactory<TCHAR, TCondensedJsonPrintPolicy<TCHAR>>::Create(&Output);
    FJsonSerializer::Serialize(Items, Writer);
    return Output;
}
