// Copyright Epic Games, Inc. All Rights Reserved.

#include "AnimGenClient.h"

#include "Misc/DateTime.h"
#include "Misc/Guid.h"
#include "Misc/Paths.h"
#include "Misc/FileHelper.h"
#include "Misc/SecureHash.h"
#include "HAL/PlatformFileManager.h"
#include "HAL/FileManager.h"
#include "Dom/JsonObject.h"
#include "Serialization/JsonSerializer.h"
#include "Serialization/JsonWriter.h"
// Native file dialogs are DesktopPlatform (editor-only dependency, see FPS.Build.cs
// Target.bBuildEditor). Keep both the include and the call sites inside WITH_EDITOR so
// Shipping/Game targets still compile; the runtime paths below degrade to "no dialog".
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
    UE_LOG(LogAnimGenClient, Log, TEXT("AnimGenClient ready (runtime-package mode)"));
}

FString UAnimGenClient::GetAssetsCacheDir()
{
    return FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("AnimAgent"), TEXT("assets"));
}

FString UAnimGenClient::GetUGCPackagesRootDir()
{
    return FPaths::Combine(FPaths::ProjectSavedDir(), TEXT("UGC"), TEXT("Packages"));
}

namespace
{
#if WITH_EDITOR
    // 仅编辑器构建有原生窗口句柄可用（Shipping 不存在文件对话框调用点）。
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
#endif
}

FString UAnimGenClient::ImportLocalUGCPackage(const FString& SourceFilePath, const FString& DesiredName, const FString& Provider)
{
    if (SourceFilePath.IsEmpty() || !FPaths::FileExists(SourceFilePath))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalUGCPackage: 源文件不存在: %s"), *SourceFilePath);
        OnAssetImportFailed.Broadcast(FString(), TEXT("源文件不存在"));
        return FString();
    }

    const FString Extension = FPaths::GetExtension(SourceFilePath, /*bIncludeDot*/false).ToLower();
    if (Extension != TEXT("glb") && Extension != TEXT("gltf") && Extension != TEXT("zip") && Extension != TEXT("ugcpkg"))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalUGCPackage: 不支持的格式: %s"), *Extension);
        OnAssetImportFailed.Broadcast(FString(), TEXT("仅支持 .glb/.gltf/.zip/.ugcpkg"));
        return FString();
    }

    const FString PackageId = FGuid::NewGuid().ToString(EGuidFormats::DigitsWithHyphensLower);
    const FString PackageDir = FPaths::Combine(GetUGCPackagesRootDir(), PackageId);
    const FString PayloadDir = FPaths::Combine(PackageDir, TEXT("payload"));
    const FString ManifestPath = FPaths::Combine(PackageDir, TEXT("manifest.json"));

    IFileManager::Get().MakeDirectory(*PayloadDir, /*Tree*/true);

    const FString OriginalName = FPaths::GetBaseFilename(SourceFilePath);
    const FString DisplayName = DesiredName.IsEmpty() ? OriginalName : DesiredName;
    const FString CleanFilename = FPaths::GetCleanFilename(SourceFilePath);
    FString ModelRelativePath;

    if (Extension == TEXT("gltf"))
    {
        const FString SourceDir = FPaths::GetPath(SourceFilePath);
        IPlatformFile& PlatformFile = FPlatformFileManager::Get().GetPlatformFile();
        if (!PlatformFile.CopyDirectoryTree(*PayloadDir, *SourceDir, /*bOverwriteAllExisting*/true))
        {
            UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalUGCPackage: 拷贝 glTF 目录失败 %s -> %s"),
                *SourceDir, *PayloadDir);
            OnAssetImportFailed.Broadcast(PackageId, TEXT("拷贝 glTF 目录失败"));
            return FString();
        }
        ModelRelativePath = FPaths::Combine(TEXT("payload"), CleanFilename);
    }
    else
    {
        const FString TargetPath = FPaths::Combine(PayloadDir, CleanFilename);
        if (IFileManager::Get().Copy(*TargetPath, *SourceFilePath) != COPY_OK)
        {
            UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalUGCPackage: 拷贝失败 %s -> %s"),
                *SourceFilePath, *TargetPath);
            OnAssetImportFailed.Broadcast(PackageId, TEXT("拷贝失败"));
            return FString();
        }
        ModelRelativePath = FPaths::Combine(TEXT("payload"), CleanFilename);
    }

    const int64 NowSeconds = FDateTime::UtcNow().ToUnixTimestamp();
    const FString Hash = LexToString(FMD5Hash::HashFile(*SourceFilePath));

    FString SourceType = TEXT("unknown");
    if (Extension == TEXT("glb")) SourceType = TEXT("glb");
    else if (Extension == TEXT("gltf")) SourceType = TEXT("gltf");
    else if (Extension == TEXT("zip")) SourceType = TEXT("zip");
    else if (Extension == TEXT("ugcpkg")) SourceType = TEXT("ugcpkg");

    TSharedRef<FJsonObject> Root = MakeShared<FJsonObject>();
    Root->SetStringField(TEXT("schema"), TEXT("ugc.runtime_package.v1"));
    Root->SetStringField(TEXT("package_id"), PackageId);
    Root->SetStringField(TEXT("asset_id"), TEXT("main"));
    Root->SetStringField(TEXT("name"), DisplayName);
    Root->SetStringField(TEXT("source_type"), SourceType);
    Root->SetStringField(TEXT("provider"), Provider.IsEmpty() ? TEXT("local") : Provider);
    Root->SetStringField(TEXT("model"), ModelRelativePath.Replace(TEXT("\\"), TEXT("/")));
    Root->SetStringField(TEXT("thumbnail"), TEXT(""));
    Root->SetStringField(TEXT("original_name"), OriginalName);
    Root->SetStringField(TEXT("original_path"), SourceFilePath);
    Root->SetStringField(TEXT("content_hash"), Hash);
    Root->SetNumberField(TEXT("created_at"), (double)NowSeconds);

    TArray<TSharedPtr<FJsonValue>> Assets;
    TSharedRef<FJsonObject> MainAsset = MakeShared<FJsonObject>();
    MainAsset->SetStringField(TEXT("asset_id"), TEXT("main"));
    MainAsset->SetStringField(TEXT("kind"), TEXT("static_mesh"));
    MainAsset->SetStringField(TEXT("model"), ModelRelativePath.Replace(TEXT("\\"), TEXT("/")));
    Assets.Add(MakeShared<FJsonValueObject>(MainAsset));
    Root->SetArrayField(TEXT("assets"), Assets);

    FString ManifestString;
    TSharedRef<TJsonWriter<>> Writer = TJsonWriterFactory<>::Create(&ManifestString);
    FJsonSerializer::Serialize(Root, Writer);
    if (!FFileHelper::SaveStringToFile(ManifestString, *ManifestPath))
    {
        UE_LOG(LogAnimGenClient, Error, TEXT("ImportLocalUGCPackage: 写 manifest 失败 %s"), *ManifestPath);
        OnAssetImportFailed.Broadcast(PackageId, TEXT("写 manifest 失败"));
        return FString();
    }

    UE_LOG(LogAnimGenClient, Log, TEXT("ImportLocalUGCPackage ok: package=%s name=%s manifest=%s"),
        *PackageId, *DisplayName, *ManifestPath);

    OnAssetImported.Broadcast(PackageId, ManifestPath);
    return PackageId;
}

TArray<FString> UAnimGenClient::OpenFileDialog(
    const FString& DialogTitle,
    const FString& DefaultPath,
    const FString& FileTypes,
    bool bAllowMulti)
{
#if WITH_EDITOR
    TArray<FString> OutFiles;
#if WITH_EDITOR
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
#else
    UE_LOG(LogAnimGenClient, Warning, TEXT("OpenFileDialog is editor-only; use ImportLocalGLB with an explicit path"));
#endif

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
    UE_LOG(LogAnimGenClient, Warning, TEXT("SaveFileDialog is editor-only; use ExportLocalGLB with an explicit path"));
    return FString();
#endif
}

FString UAnimGenClient::ImportLocalGLB(const FString& SourceFilePath, const FString& DesiredName)
{
    return ImportLocalUGCPackage(SourceFilePath, DesiredName, TEXT("local"));
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
