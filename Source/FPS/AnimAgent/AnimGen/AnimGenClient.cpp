// Copyright Epic Games, Inc. All Rights Reserved.

#include "AnimGenClient.h"

#include "Misc/Guid.h"
#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "HAL/PlatformFileManager.h"
#include "HAL/FileManager.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
#if WITH_EDITOR
#include "DesktopPlatformModule.h"
#include "IDesktopPlatform.h"
#endif
#include "Framework/Application/SlateApplication.h"

DEFINE_LOG_CATEGORY_STATIC(LogAnimGenClient, Log, All);

UAnimGenClient::UAnimGenClient()
{
    PrimaryComponentTick.bCanEverTick = false;
}

void UAnimGenClient::BeginPlay()
{
    Super::BeginPlay();
    UE_LOG(LogAnimGenClient, Log, TEXT("AnimGenClient ready (local-import mode)"));
}

FString UAnimGenClient::GetAssetsCacheDir()
{
    return FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("AnimAgent"), TEXT("assets"));
}

#if WITH_EDITOR
namespace
{
    void* GetParentWindowHandle()
    {
        if (FSlateApplication::IsInitialized())
        {
            TSharedPtr<SWindow> Win = FSlateApplication::Get().GetActiveTopLevelWindow();
            if (Win.IsValid() && Win->GetNativeWindow().IsValid())
            {
                return Win->GetNativeWindow()->GetOSWindowHandle();
            }
        }
        return nullptr;
    }
}
#endif

TArray<FString> UAnimGenClient::OpenFileDialog(
    const FString& DialogTitle,
    const FString& DefaultPath,
    const FString& FileTypes,
    bool bAllowMulti)
{
#if WITH_EDITOR
    TArray<FString> OutFiles;
    IDesktopPlatform* Desktop = FDesktopPlatformModule::Get();
    if (!Desktop) return OutFiles;

    const uint32 Flags = bAllowMulti
        ? (uint32)EFileDialogFlags::Multiple
        : (uint32)EFileDialogFlags::None;

    Desktop->OpenFileDialog(
        GetParentWindowHandle(),
        DialogTitle,
        DefaultPath,
        TEXT(""),
        FileTypes,
        Flags,
        OutFiles);

    return OutFiles;
#else
    // 原生文件对话框是编辑器专属能力（DesktopPlatform 只在 bBuildEditor 下链接）。
    // Shipping/运行时请由 UI 传入已知路径，例如 AnimAgentCore:ImportLocal(filePath, name)。
    UE_LOG(LogAnimGenClient, Warning, TEXT("OpenFileDialog 仅编辑器可用；运行时请直接传入文件路径"));
    return TArray<FString>();
#endif
}

FString UAnimGenClient::SaveFileDialog(
    const FString& DialogTitle,
    const FString& DefaultPath,
    const FString& DefaultFileName,
    const FString& FileTypes)
{
#if WITH_EDITOR
    IDesktopPlatform* Desktop = FDesktopPlatformModule::Get();
    if (!Desktop) return FString();

    TArray<FString> OutFiles;
    if (!Desktop->SaveFileDialog(
            GetParentWindowHandle(),
            DialogTitle,
            DefaultPath,
            DefaultFileName,
            FileTypes,
            (uint32)EFileDialogFlags::None,
            OutFiles))
    {
        return FString();
    }
    return OutFiles.Num() > 0 ? OutFiles[0] : FString();
#else
    // 同 OpenFileDialog：编辑器专属，运行时由调用方提供目标路径。
    UE_LOG(LogAnimGenClient, Warning, TEXT("SaveFileDialog 仅编辑器可用；运行时请直接指定目标路径"));
    return FString();
#endif
}

FString UAnimGenClient::ImportLocalGLB(const FString& SourceFilePath, const FString& DesiredName)
{
    if (SourceFilePath.IsEmpty() || !FPaths::FileExists(SourceFilePath))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalGLB: 源文件不存在: %s"), *SourceFilePath);
        OnAssetImportFailed.Broadcast(FString(), TEXT("源文件不存在"));
        return FString();
    }

    const FString Extension = FPaths::GetExtension(SourceFilePath, /*bIncludeDot*/false).ToLower();
    if (Extension != TEXT("glb"))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalGLB: 仅支持 .glb，当前: %s"), *Extension);
        OnAssetImportFailed.Broadcast(FString(), TEXT("仅支持 .glb 文件"));
        return FString();
    }

    const FString Uuid = FGuid::NewGuid().ToString(EGuidFormats::DigitsWithHyphensLower);
    const FString TargetDir = FPaths::Combine(GetAssetsCacheDir(), Uuid);
    const FString TargetPath = FPaths::Combine(TargetDir, TEXT("source.glb"));

    IFileManager::Get().MakeDirectory(*TargetDir, /*Tree*/true);

    if (IFileManager::Get().Copy(*TargetPath, *SourceFilePath) != COPY_OK)
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalGLB: 拷贝失败 %s -> %s"),
            *SourceFilePath, *TargetPath);
        OnAssetImportFailed.Broadcast(Uuid, TEXT("拷贝失败"));
        return FString();
    }

    // 落 meta.json（玩家把 Saved 目录拷走也能识别来源）
    const FString OriginalName = FPaths::GetBaseFilename(SourceFilePath);
    const FString DisplayName = DesiredName.IsEmpty() ? OriginalName : DesiredName;
    const int64 NowSeconds = FDateTime::UtcNow().ToUnixTimestamp();

    TSharedRef<FJsonObject> Meta = MakeShared<FJsonObject>();
    Meta->SetStringField(TEXT("uuid"), Uuid);
    Meta->SetStringField(TEXT("name"), DisplayName);
    Meta->SetStringField(TEXT("source"), TEXT("Local"));
    Meta->SetStringField(TEXT("source_note"), OriginalName);
    Meta->SetStringField(TEXT("original_path"), SourceFilePath);
    Meta->SetNumberField(TEXT("created_at"), (double)NowSeconds);

    FString MetaStr;
    TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&MetaStr);
    FJsonSerializer::Serialize(Meta, Writer);
    FFileHelper::SaveStringToFile(MetaStr, *FPaths::Combine(TargetDir, TEXT("meta.json")));

    UE_LOG(LogAnimGenClient, Log, TEXT("ImportLocalGLB ok: uuid=%s name=%s -> %s"),
        *Uuid, *DisplayName, *TargetPath);

    OnAssetImported.Broadcast(Uuid, TargetPath);
    return Uuid;
}

bool UAnimGenClient::ExportLocalGLB(const FString& AssetUuid, const FString& TargetFilePath)
{
    if (AssetUuid.IsEmpty() || TargetFilePath.IsEmpty())
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ExportLocalGLB: 参数为空"));
        return false;
    }

    const FString SourceDir = FPaths::Combine(GetAssetsCacheDir(), AssetUuid);
    const FString SourceGLB = FPaths::Combine(SourceDir, TEXT("source.glb"));
    if (!FPaths::FileExists(SourceGLB))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ExportLocalGLB: 资产 %s 的 source.glb 不存在"), *AssetUuid);
        return false;
    }

    // 确保目标目录存在
    const FString TargetDir = FPaths::GetPath(TargetFilePath);
    IFileManager::Get().MakeDirectory(*TargetDir, /*Tree*/true);

    if (IFileManager::Get().Copy(*TargetFilePath, *SourceGLB) != COPY_OK)
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ExportLocalGLB: 拷贝失败 -> %s"), *TargetFilePath);
        return false;
    }

    // 同目录顺手输出 .meta.json（带 uuid 和原始 meta 拷贝）
    const FString SourceMeta = FPaths::Combine(SourceDir, TEXT("meta.json"));
    if (FPaths::FileExists(SourceMeta))
    {
        const FString TargetMeta = TargetFilePath + TEXT(".meta.json");
        IFileManager::Get().Copy(*TargetMeta, *SourceMeta);
    }

    UE_LOG(LogAnimGenClient, Log, TEXT("ExportLocalGLB ok: %s -> %s"), *AssetUuid, *TargetFilePath);
    return true;
}
