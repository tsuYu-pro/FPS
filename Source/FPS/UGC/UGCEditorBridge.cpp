// Copyright Epic Games, Inc. All Rights Reserved.

#include "UGCEditorBridge.h"
#include "Engine/World.h"
#include "GameFramework/PlayerController.h"
#include "Components/PrimitiveComponent.h"
#include "CollisionQueryParams.h"
#include "HAL/FileManager.h"
#include "DrawDebugHelpers.h"
#include "InputCoreTypes.h"
#if WITH_EDITOR
#include "DesktopPlatformModule.h"
#include "IDesktopPlatform.h"
#include "Framework/Application/SlateApplication.h"
#endif

UUGCEditorBridge::UUGCEditorBridge()
{
    PrimaryComponentTick.bCanEverTick = false;
}

AActor* UUGCEditorBridge::SpawnPlaceable(const FString& BlueprintPath, FVector Location, FRotator Rotation)
{
    if (!GetOwner() || !GetOwner()->HasAuthority()) return nullptr;
    if (!BlueprintPath.StartsWith(TEXT("/Game/_UGC/Placeables/"))
        && !BlueprintPath.StartsWith(TEXT("/Game/_UGC/Editor/Actor/")))
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCEditorBridge] Rejected asset path '%s'"), *BlueprintPath);
        return nullptr;
    }

    UWorld* World = GetWorld();
    if (!World) return nullptr;

    UClass* Class = LoadClass<AActor>(nullptr, *BlueprintPath);
    if (!Class)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCEditorBridge] SpawnPlaceable: 找不到类 '%s'"), *BlueprintPath);
        return nullptr;
    }

    FActorSpawnParameters Params;
    Params.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AdjustIfPossibleButAlwaysSpawn;

    AActor* Actor = World->SpawnActor<AActor>(Class, Location, Rotation, Params);
    if (!Actor)
    {
        UE_LOG(LogTemp, Warning, TEXT("[UGCEditorBridge] SpawnPlaceable: Spawn 失败 '%s'"), *BlueprintPath);
    }
    else
    {
        SpawnedActors.Add(Actor);
    }
    return Actor;
}

void UUGCEditorBridge::DestroyActor(AActor* Actor)
{
    TryDestroyActor(Actor);
}

bool UUGCEditorBridge::TryDestroyActor(AActor* Actor)
{
    if (!GetOwner() || !GetOwner()->HasAuthority() || !Actor || !SpawnedActors.Contains(Actor)) return false;
    SpawnedActors.Remove(Actor);
    return !IsValid(Actor) || Actor->Destroy();
}

AActor* UUGCEditorBridge::LineTraceScreen(float ScreenX, float ScreenY)
{
    APlayerController* PC = GetPC();
    if (!PC) return nullptr;

    FVector WorldPos, WorldDir;
    if (!PC->DeprojectScreenPositionToWorld(ScreenX, ScreenY, WorldPos, WorldDir))
        return nullptr;

    FVector Start = WorldPos;
    FVector End   = WorldPos + WorldDir * 50000.f;

    FHitResult Hit;
    FCollisionQueryParams QueryParams;
    QueryParams.AddIgnoredActor(PC->GetPawn());

    bool bHit = GetWorld()->LineTraceSingleByChannel(
        Hit, Start, End,
        ECollisionChannel::ECC_Visibility,
        QueryParams
    );

    return bHit ? Hit.GetActor() : nullptr;
}

void UUGCEditorBridge::SetActorHighlight(AActor* Actor, bool bEnable)
{
    if (!Actor || !IsValid(Actor)) return;

    // 遍历所有 PrimitiveComponent 开关描边
    TArray<UPrimitiveComponent*> Prims;
    Actor->GetComponents<UPrimitiveComponent>(Prims);
    for (UPrimitiveComponent* Prim : Prims)
    {
        if (Prim)
        {
            Prim->SetRenderCustomDepth(bEnable);
            Prim->SetCustomDepthStencilValue(bEnable ? 1 : 0);
        }
    }
}

FTransform UUGCEditorBridge::GetActorTransform(AActor* Actor) const
{
    if (!Actor || !IsValid(Actor)) return FTransform::Identity;
    return Actor->GetActorTransform();
}

void UUGCEditorBridge::SetActorTransform(AActor* Actor, const FTransform& NewTransform)
{
    TrySetActorTransform(Actor, NewTransform);
}

bool UUGCEditorBridge::TrySetActorTransform(AActor* Actor, const FTransform& NewTransform)
{
    if (!GetOwner() || !GetOwner()->HasAuthority() || !Actor || !IsValid(Actor)
        || !SpawnedActors.Contains(Actor)) return false;
    return Actor->SetActorTransform(NewTransform);
}

void UUGCEditorBridge::SetActorTranslucencySortPriority(AActor* Actor, int32 Priority)
{
    if (!Actor || !IsValid(Actor)) return;

    TArray<UPrimitiveComponent*> Prims;
    Actor->GetComponents<UPrimitiveComponent>(Prims);
    for (UPrimitiveComponent* Prim : Prims)
    {
        if (!Prim) continue;
        Prim->TranslucencySortPriority = Priority;
        Prim->MarkRenderStateDirty();
    }
}

void UUGCEditorBridge::SetActorDepthPriorityForeground(AActor* Actor, bool bForeground)
{
    if (!Actor || !IsValid(Actor)) return;

    TArray<UPrimitiveComponent*> Prims;
    Actor->GetComponents<UPrimitiveComponent>(Prims);
    for (UPrimitiveComponent* Prim : Prims)
    {
        if (!Prim) continue;
        Prim->SetDepthPriorityGroup(bForeground ? SDPG_Foreground : SDPG_World);
        Prim->MarkRenderStateDirty();
    }
}

float UUGCEditorBridge::GetActorLocalBoundsMinZ(AActor* Actor) const
{
    if (!Actor || !IsValid(Actor)) return 0.f;

    const FBox LocalBounds = Actor->CalculateComponentsBoundingBoxInLocalSpace();
    return LocalBounds.Min.Z;
}

FVector UUGCEditorBridge::LineTraceScreenPosition(float ScreenX, float ScreenY, AActor* ActorToIgnore)
{
    APlayerController* PC = GetPC();
    if (!PC) return FVector::ZeroVector;

    FVector WorldPos, WorldDir;
    if (!PC->DeprojectScreenPositionToWorld(ScreenX, ScreenY, WorldPos, WorldDir))
        return FVector::ZeroVector;

    FVector Start = WorldPos;
    FVector End   = WorldPos + WorldDir * 50000.f;

    FHitResult Hit;
    FCollisionQueryParams QueryParams;
    QueryParams.AddIgnoredActor(PC->GetPawn());
    if (ActorToIgnore && IsValid(ActorToIgnore))
    {
        QueryParams.AddIgnoredActor(ActorToIgnore);
    }

    bool bHit = GetWorld()->LineTraceSingleByChannel(
        Hit, Start, End,
        ECollisionChannel::ECC_Visibility,
        QueryParams
    );

    return bHit ? Hit.ImpactPoint : FVector::ZeroVector;
}

FVector UUGCEditorBridge::LineTraceScreenPositionMulti(float ScreenX, float ScreenY, const TArray<AActor*>& ActorsToIgnore)
{
    APlayerController* PC = GetPC();
    if (!PC) return FVector::ZeroVector;

    FVector WorldPos, WorldDir;
    if (!PC->DeprojectScreenPositionToWorld(ScreenX, ScreenY, WorldPos, WorldDir))
        return FVector::ZeroVector;

    FVector Start = WorldPos;
    FVector End   = WorldPos + WorldDir * 50000.f;

    FHitResult Hit;
    FCollisionQueryParams QueryParams;
    QueryParams.AddIgnoredActor(PC->GetPawn());
    for (AActor* A : ActorsToIgnore)
    {
        if (A && IsValid(A))
            QueryParams.AddIgnoredActor(A);
    }

    bool bHit = GetWorld()->LineTraceSingleByChannel(
        Hit, Start, End,
        ECollisionChannel::ECC_Visibility,
        QueryParams
    );

    return bHit ? Hit.ImpactPoint : FVector::ZeroVector;
}

APlayerController* UUGCEditorBridge::GetPC() const
{
    return Cast<APlayerController>(GetOwner());
}

TArray<FString> UUGCEditorBridge::FindFilesInDirectory(const FString& Directory, const FString& WildCard)
{
    TArray<FString> Result;
#if WITH_EDITOR
    IFileManager::Get().FindFilesRecursive(Result, *Directory, *WildCard, /*Files=*/true, /*Dirs=*/false);
#else
    UE_LOG(LogTemp, Verbose, TEXT("[UGCEditorBridge] Runtime asset scanning is disabled; use the packaged prefab catalog"));
#endif
    return Result;
}

void UUGCEditorBridge::DrawActorAxes(AActor* Actor, float AxisLength)
{
    if (!Actor || !IsValid(Actor)) return;
    UWorld* World = GetWorld();
    if (!World) return;

    const FVector Origin    = Actor->GetActorLocation();
    const FTransform TForm  = Actor->GetActorTransform();
    const float ArrowSize   = AxisLength * 0.2f;

    // X 轴 — 红色
    DrawDebugDirectionalArrow(World,
        Origin,
        Origin + TForm.GetUnitAxis(EAxis::X) * AxisLength,
        ArrowSize, FColor::Red,
        /*bPersistentLines=*/true, /*LifeTime=*/-1.f, /*DepthPriority=*/0, /*Thickness=*/2.0f);

    // Y 轴 — 绿色
    DrawDebugDirectionalArrow(World,
        Origin,
        Origin + TForm.GetUnitAxis(EAxis::Y) * AxisLength,
        ArrowSize, FColor::Green,
        /*bPersistentLines=*/true, /*LifeTime=*/-1.f, /*DepthPriority=*/0, /*Thickness=*/2.0f);

    // Z 轴 — 蓝色
    DrawDebugDirectionalArrow(World,
        Origin,
        Origin + TForm.GetUnitAxis(EAxis::Z) * AxisLength,
        ArrowSize, FColor::Blue,
        /*bPersistentLines=*/true, /*LifeTime=*/-1.f, /*DepthPriority=*/0, /*Thickness=*/2.0f);
}

bool UUGCEditorBridge::IsMouseButtonDown()
{
    APlayerController* PC = GetPC();
    if (!PC) return false;
    return PC->IsInputKeyDown(EKeys::LeftMouseButton);
}

bool UUGCEditorBridge::IsEscapeDown()
{
    APlayerController* PC = GetPC();
    if (!PC) return false;
    return PC->IsInputKeyDown(EKeys::Escape);
}

#if WITH_EDITOR
static void* GetUGCDialogParentWindowHandle()
{
    TSharedPtr<SWindow> TopWindow = FSlateApplication::Get().GetActiveTopLevelWindow();
    if (TopWindow.IsValid() && TopWindow->GetNativeWindow().IsValid())
    {
        return TopWindow->GetNativeWindow()->GetOSWindowHandle();
    }
    return nullptr;
}
#endif

FString UUGCEditorBridge::ShowSaveFileDialog(const FString& Title, const FString& DefaultPath, const FString& DefaultFile, const FString& FileType)
{
#if WITH_EDITOR
    IDesktopPlatform* DP = FDesktopPlatformModule::Get();
    if (!DP) return TEXT("");

    TArray<FString> OutFiles;
    const bool bOK = DP->SaveFileDialog(GetUGCDialogParentWindowHandle(), Title, DefaultPath, DefaultFile, FileType, EFileDialogFlags::None, OutFiles);
    return (bOK && OutFiles.Num() > 0) ? OutFiles[0] : TEXT("");
#else
    UE_LOG(LogTemp, Warning, TEXT("[UGCEditorBridge] Native save dialog is editor-only"));
    return TEXT("");
#endif
}

FString UUGCEditorBridge::ShowOpenFileDialog(const FString& Title, const FString& DefaultPath, const FString& FileType)
{
#if WITH_EDITOR
    IDesktopPlatform* DP = FDesktopPlatformModule::Get();
    if (!DP) return TEXT("");

    TArray<FString> OutFiles;
    const bool bOK = DP->OpenFileDialog(GetUGCDialogParentWindowHandle(), Title, DefaultPath, TEXT(""), FileType, EFileDialogFlags::None, OutFiles);
    return (bOK && OutFiles.Num() > 0) ? OutFiles[0] : TEXT("");
#else
    UE_LOG(LogTemp, Warning, TEXT("[UGCEditorBridge] Native open dialog is editor-only"));
    return TEXT("");
#endif
}

bool UUGCEditorBridge::SupportsNativeFileDialogs() const
{
#if WITH_EDITOR
    return true;
#else
    return false;
#endif
}

void UUGCEditorBridge::ClearDebugAxes()
{
    UWorld* World = GetWorld();
    if (World)
    {
        // 清除所有持久调试线（坐标轴箭头）
        FlushPersistentDebugLines(World);
    }
}

