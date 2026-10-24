// Copyright Epic Games, Inc. All Rights Reserved.

#include "FPSWeaponBase.h"
#include "FPSWeaponDataAsset.h"
#include "FPSWeaponAttachmentData.h"
#include "FPSProjectile.h"
#include "FPS/FPSCharacter.h"
#include "FPS/GAS/FPSAbilitySystemComponent.h"
#include "FPS/GAS/FPSGameplayAbility.h"
#include "FPS/GAS/FPSRecoilComponent.h"
#include "AbilitySystemComponent.h"
#include "Components/SkeletalMeshComponent.h"
#include "Kismet/GameplayStatics.h"
#include "Engine/AssetManager.h"
#include "Net/UnrealNetwork.h"
#include "Particles/ParticleSystemComponent.h"

const FName AFPSWeaponBase::MuzzleSocketName = TEXT("Muzzle");

AFPSWeaponBase::AFPSWeaponBase()
{
	PrimaryActorTick.bCanEverTick = false;
	bReplicates = true;

	// Root scene component so WeaponMesh can be freely transformed in Blueprint
	USceneComponent* SceneRoot = CreateDefaultSubobject<USceneComponent>(TEXT("SceneRoot"));
	RootComponent = SceneRoot;

	// Create weapon mesh
	WeaponMesh = CreateDefaultSubobject<USkeletalMeshComponent>(TEXT("WeaponMesh"));
	WeaponMesh->SetupAttachment(RootComponent);
	WeaponMesh->SetCollisionEnabled(ECollisionEnabled::NoCollision);
}

void AFPSWeaponBase::GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const
{
	Super::GetLifetimeReplicatedProps(OutLifetimeProps);

	DOREPLIFETIME(AFPSWeaponBase, InstalledAttachmentIDs);
}

void AFPSWeaponBase::BeginPlay()
{
	Super::BeginPlay();

	// 先重建配件缓存，保证下面的有效属性计算能吃到（可能的）预装配件
	RebuildAttachmentCache();

	// Initialize ammo from weapon data
	if (WeaponData)
	{
		AmmoInfo = WeaponData->GetDefaultAmmoInfo();
		// Use effective magazine size (accounts for pre-installed attachments)
		AmmoInfo.MaxMagazine = GetEffectiveMagazineSize();
		AmmoInfo.CurrentMagazine = AmmoInfo.MaxMagazine;
	}
}

void AFPSWeaponBase::OnRep_InstalledAttachments()
{
	// 以"旧缓存下的槽位集合"作为变化前的代理
	TSet<EFPSAttachmentSlotType> ChangedSlots;
	for (const TPair<EFPSAttachmentSlotType, UFPSWeaponAttachmentData*>& Old : CachedAttachmentData)
	{
		ChangedSlots.Add(Old.Key);
	}

	RebuildAttachmentCache();

	for (const TPair<EFPSAttachmentSlotType, UFPSWeaponAttachmentData*>& New : CachedAttachmentData)
	{
		ChangedSlots.Add(New.Key);
	}

	// 按槽广播（排序保证确定性）
	TArray<EFPSAttachmentSlotType> SortedSlots = ChangedSlots.Array();
	SortedSlots.Sort([](const EFPSAttachmentSlotType& A, const EFPSAttachmentSlotType& B)
	{
		return static_cast<uint8>(A) < static_cast<uint8>(B);
	});
	for (EFPSAttachmentSlotType Slot : SortedSlots)
	{
		OnAttachmentsChanged.Broadcast(Slot);
	}
}

void AFPSWeaponBase::RebuildAttachmentCache()
{
	CachedAttachmentData.Reset();

	if (InstalledAttachmentIDs.IsEmpty())
	{
		return;
	}

	UAssetManager* AssetManager = UAssetManager::GetIfInitialized();

	for (const FFPSInstalledAttachment& Entry : InstalledAttachmentIDs)
	{
		if (Entry.AttachmentID.IsNone())
		{
			continue;
		}

		UFPSWeaponAttachmentData* Data = nullptr;

		if (AssetManager)
		{
			const FPrimaryAssetId PrimaryId(TEXT("AttachmentData"), Entry.AttachmentID);
			Data = Cast<UFPSWeaponAttachmentData>(AssetManager->GetPrimaryAssetObject(PrimaryId));

			if (!Data)
			{
				// 未加载：按主资产路径同步加载（阶段一：小体量够用；资产多时改异步）
				const FSoftObjectPath AssetPath = AssetManager->GetPrimaryAssetPath(PrimaryId);
				if (AssetPath.IsValid())
				{
					Data = Cast<UFPSWeaponAttachmentData>(AssetPath.TryLoad());
				}
			}
		}

		if (Data)
		{
			CachedAttachmentData.Add(Entry.Slot, Data);
		}
		else
		{
			UE_LOG(LogTemp, Warning,
				TEXT("[Attachment] 无法解析附件资产 '%s'（检查 AssetManager 是否扫描 AttachmentData 类型、资产是否存在）"),
				*Entry.AttachmentID.ToString());
		}
	}
}

void AFPSWeaponBase::OnEquip(AFPSCharacter* NewOwner)
{
	if (!NewOwner)
	{
		return;
	}

	OwningCharacter = NewOwner;
	SetOwner(NewOwner);
	SetInstigator(NewOwner);
	SetWeaponState(EFPSWeaponState::Equipping);

	// Grant abilities
	GrantAbilities();

	// Set equip timer
	if (WeaponData)
	{
		FTimerHandle EquipTimerHandle;
		GetWorldTimerManager().SetTimer(
			EquipTimerHandle,
			[this]() { SetWeaponState(EFPSWeaponState::Idle); },
			WeaponData->EquipTime,
			false
		);
	}
	else
	{
		SetWeaponState(EFPSWeaponState::Idle);
	}

	// Broadcast ammo state
	OnAmmoChanged.Broadcast(AmmoInfo.CurrentMagazine, AmmoInfo.CurrentReserve);
}

void AFPSWeaponBase::OnUnequip()
{
	SetWeaponState(EFPSWeaponState::Unequipping);

	// Remove abilities
	RemoveAbilities();

	// Clear timers
	GetWorldTimerManager().ClearTimer(FireCooldownTimerHandle);
	GetWorldTimerManager().ClearTimer(ReloadTimerHandle);

	OwningCharacter.Reset();
}

bool AFPSWeaponBase::TryFire()
{
	if (!CanFire())
	{
		// Play dry fire sound if magazine empty
		if (WeaponData && AmmoInfo.IsMagazineEmpty() && WeaponData->DryFireSound.IsValid())
		{
			UGameplayStatics::PlaySoundAtLocation(this, WeaponData->DryFireSound.LoadSynchronous(), GetActorLocation());
		}
		return false;
	}

	Fire();
	return true;
}

void AFPSWeaponBase::Fire()
{
	if (!WeaponData)
	{
		return;
	}

	// Consume ammo
	if (WeaponData->bUsesAmmo)
	{
		AmmoInfo.ConsumeAmmo();
		OnAmmoChanged.Broadcast(AmmoInfo.CurrentMagazine, AmmoInfo.CurrentReserve);
	}

	// Set fire cooldown
	bCanFireAgain = false;
	float FireDelay = WeaponData->GetTimeBetweenShots();
	GetWorldTimerManager().SetTimer(
		FireCooldownTimerHandle,
		this,
		&AFPSWeaponBase::ResetFireCooldown,
		FireDelay,
		false
	);

	// 通知后坐力系统（Lua 重写此函数以推进 Pattern Index）
	OnShotFired();

	const FVector MuzzleLoc = GetMuzzleLocation();

	// 客户端：预测表现（音效/枪口火焰），然后 RPC 到服务端执行 spawn
	if (OwningCharacter.IsValid() && OwningCharacter->IsLocallyControlled() && !HasAuthority())
	{
		PlayFireEffectsLocally(MuzzleLoc);
		const FVector FireDir = OwningCharacter->GetControlRotation().Vector();
		ServerFire(MuzzleLoc, FireDir);
		return;
	}

	// 服务端 / Standalone：始终 spawn 弹体（权威路径）
	SpawnProjectile(MuzzleLoc);
	PlayFireEffectsLocally(MuzzleLoc);
	MulticastFireEffects(MuzzleLoc);
}

//-------------------------------------------------------------------
// Network RPCs
//-------------------------------------------------------------------

bool AFPSWeaponBase::ServerFire_Validate(FVector MuzzleLocation, FVector FireDirection)
{
	// Basic validation: check muzzle position isn't too far from expected
	FVector ServerMuzzle = GetMuzzleLocation();
	float Distance = FVector::Dist(MuzzleLocation, ServerMuzzle);
	return Distance <= MaxMuzzlePositionError;
}

void AFPSWeaponBase::ServerFire_Implementation(FVector MuzzleLocation, FVector FireDirection)
{
	if (!WeaponData || !CanFire())
	{
		return;
	}

	// Consume ammo on server
	if (WeaponData->bUsesAmmo)
	{
		AmmoInfo.ConsumeAmmo();
		OnAmmoChanged.Broadcast(AmmoInfo.CurrentMagazine, AmmoInfo.CurrentReserve);
	}

	// Set fire cooldown on server
	bCanFireAgain = false;
	float FireDelay = WeaponData->GetTimeBetweenShots();
	GetWorldTimerManager().SetTimer(
		FireCooldownTimerHandle,
		this,
		&AFPSWeaponBase::ResetFireCooldown,
		FireDelay,
		false
	);

	// 通知后坐力系统
	OnShotFired();

	// 服务端权威路径：spawn 弹体，Replicate 到所有客户端
	SpawnProjectile(MuzzleLocation);
	MulticastFireEffects(MuzzleLocation);
}

void AFPSWeaponBase::MulticastFireEffects_Implementation(FVector MuzzleLocation)
{
	// 跳过本地玩家（客户端预测时已经播过了）
	if (OwningCharacter.IsValid() && OwningCharacter->IsLocallyControlled())
	{
		return;
	}

	PlayFireEffectsLocally(MuzzleLocation);
}

void AFPSWeaponBase::PlayFireEffectsLocally(FVector MuzzleLocation)
{
	if (!WeaponData)
	{
		return;
	}

	// 1. 枪口火焰特效（优先 Attach 到 Muzzle 插槽，跟随武器移动）
	if (WeaponData->MuzzleFlashEffect.IsValid())
	{
		UParticleSystem* MuzzleVFX = WeaponData->MuzzleFlashEffect.LoadSynchronous();
		if (MuzzleVFX)
		{
			if (WeaponMesh && WeaponMesh->DoesSocketExist(MuzzleSocketName))
			{
				UGameplayStatics::SpawnEmitterAttached(
					MuzzleVFX,
					WeaponMesh,
					MuzzleSocketName,
					FVector::ZeroVector,
					FRotator::ZeroRotator,
					EAttachLocation::SnapToTarget
				);
			}
			else
			{
				UGameplayStatics::SpawnEmitterAtLocation(this, MuzzleVFX, MuzzleLocation, GetMuzzleRotation());
			}
		}
	}

	// 2. 开火音效
	// 曳光线与命中特效已迁移到 AFPSProjectile::PlayImpactEffects，此处不再负责
	if (WeaponData->FireSound.IsValid())
	{
		UGameplayStatics::PlaySoundAtLocation(this, WeaponData->FireSound.LoadSynchronous(), MuzzleLocation);
	}
}

bool AFPSWeaponBase::TryReload()
{
	if (!CanReload())
	{
		return false;
	}

	Reload();
	return true;
}

void AFPSWeaponBase::Reload()
{
	if (!WeaponData)
	{
		return;
	}

	SetWeaponState(EFPSWeaponState::Reloading);

	// Play reload sound
	if (WeaponData->ReloadStartSound.IsValid())
	{
		UGameplayStatics::PlaySoundAtLocation(this, WeaponData->ReloadStartSound.LoadSynchronous(), GetActorLocation());
	}

	// Set reload timer (uses effective reload time including attachment modifiers)
	GetWorldTimerManager().SetTimer(
		ReloadTimerHandle,
		this,
		&AFPSWeaponBase::FinishReload,
		GetEffectiveReloadTime(),
		false
	);
}

void AFPSWeaponBase::FinishReload()
{
	if (CurrentState != EFPSWeaponState::Reloading)
	{
		return;
	}

	// Refill magazine
	AmmoInfo.Reload();
	OnAmmoChanged.Broadcast(AmmoInfo.CurrentMagazine, AmmoInfo.CurrentReserve);

	// Play finish sound
	if (WeaponData && WeaponData->ReloadFinishSound.IsValid())
	{
		UGameplayStatics::PlaySoundAtLocation(this, WeaponData->ReloadFinishSound.LoadSynchronous(), GetActorLocation());
	}

	SetWeaponState(EFPSWeaponState::Idle);
}

void AFPSWeaponBase::CancelReload()
{
	if (CurrentState == EFPSWeaponState::Reloading)
	{
		GetWorldTimerManager().ClearTimer(ReloadTimerHandle);
		SetWeaponState(EFPSWeaponState::Idle);
	}
}

void AFPSWeaponBase::MeleeAttack()
{
	// Base implementation - override in subclasses for melee weapons
}

bool AFPSWeaponBase::CanFire() const
{
	if (!bCanFireAgain)
	{
		return false;
	}

	if (CurrentState != EFPSWeaponState::Idle && CurrentState != EFPSWeaponState::Firing)
	{
		return false;
	}

	if (WeaponData && WeaponData->bUsesAmmo && AmmoInfo.IsMagazineEmpty())
	{
		return false;
	}

	return true;
}

bool AFPSWeaponBase::CanReload() const
{
	if (CurrentState != EFPSWeaponState::Idle)
	{
		return false;
	}

	if (!WeaponData || !WeaponData->bUsesAmmo)
	{
		return false;
	}

	return AmmoInfo.CanReload();
}

int32 AFPSWeaponBase::AddAmmo(int32 Amount)
{
	int32 Leftover = AmmoInfo.AddReserve(Amount);
	OnAmmoChanged.Broadcast(AmmoInfo.CurrentMagazine, AmmoInfo.CurrentReserve);
	return Leftover;
}

int32 AFPSWeaponBase::GetMagazineCapacity() const
{
	return GetEffectiveMagazineSize();
}

FVector AFPSWeaponBase::GetMuzzleLocation() const
{
	if (WeaponMesh && WeaponMesh->DoesSocketExist(MuzzleSocketName))
	{
		return WeaponMesh->GetSocketLocation(MuzzleSocketName);
	}

	// Fallback to actor location
	return GetActorLocation();
}

FRotator AFPSWeaponBase::GetMuzzleRotation() const
{
	if (WeaponMesh && WeaponMesh->DoesSocketExist(MuzzleSocketName))
	{
		return WeaponMesh->GetSocketRotation(MuzzleSocketName);
	}

	// Fallback to owner's control rotation
	if (OwningCharacter.IsValid())
	{
		return OwningCharacter->GetControlRotation();
	}

	return GetActorRotation();
}

FVector AFPSWeaponBase::GetFireDirectionWithSpread_Implementation()
{
	FVector BaseDirection = OwningCharacter.IsValid()
		? OwningCharacter->GetControlRotation().Vector()
		: GetActorForwardVector();

	// RecoilComponent 负责 Pattern + Spread（Lua 可完全重写此函数）
	if (OwningCharacter.IsValid() && OwningCharacter->RecoilComponent)
	{
		return OwningCharacter->RecoilComponent->GetFireDirection(BaseDirection);
	}

	return BaseDirection.GetSafeNormal();
}

UAbilitySystemComponent* AFPSWeaponBase::GetOwnerASC() const
{
	if (OwningCharacter.IsValid())
	{
		return OwningCharacter->GetAbilitySystemComponent();
	}
	return nullptr;
}

void AFPSWeaponBase::SpawnProjectile(const FVector& MuzzleLocation)
{
	if (!WeaponData || !WeaponData->ProjectileClass)
	{
		return;
	}

	FVector FireDir = GetFireDirectionWithSpread();

	FActorSpawnParameters SpawnParams;
	SpawnParams.Owner      = this;
	SpawnParams.Instigator = OwningCharacter.Get();
	SpawnParams.SpawnCollisionHandlingOverride = ESpawnActorCollisionHandlingMethod::AlwaysSpawn;

	FTransform SpawnTransform(FireDir.Rotation(), MuzzleLocation);
	if (AFPSProjectile* Proj = GetWorld()->SpawnActor<AFPSProjectile>(
		WeaponData->ProjectileClass, SpawnTransform, SpawnParams))
	{
		Proj->Launch(FireDir, WeaponData, OwningCharacter.Get());
		// Launch() 内部写的是 WeaponData->BaseDamage，用配件修正后的有效伤害覆盖
		Proj->Damage = GetEffectiveDamage();
	}
}

void AFPSWeaponBase::SetWeaponState(EFPSWeaponState NewState)
{
	if (CurrentState != NewState)
	{
		CurrentState = NewState;
		OnWeaponStateChanged.Broadcast(NewState);
	}
}

void AFPSWeaponBase::OnShotFired_Implementation()
{
	// 空实现。CurrentPatternIndex 的推进及 Pattern 重置计时由 Lua（RecoilComponent）管理。
}

void AFPSWeaponBase::GrantAbilities()
{
	if (!HasAuthority())
	{
		return;
	}

	UAbilitySystemComponent* ASC = GetOwnerASC();
	if (!ASC)
	{
		return;
	}

	auto GrantOne = [&](TSubclassOf<UGameplayAbility> AbilityClass)
	{
		if (AbilityClass)
		{
			FGameplayAbilitySpec Spec(AbilityClass, 1, INDEX_NONE, this);
			GrantedAbilityHandles.Add(ASC->GiveAbility(Spec));
		}
	};

	if (WeaponData)
	{
		GrantOne(WeaponData->FireAbilityClass);
		GrantOne(WeaponData->ReloadAbilityClass);
		GrantOne(WeaponData->MeleeAbilityClass);
	}

	for (const TSubclassOf<UFPSGameplayAbility>& AbilityClass : WeaponAbilities)
	{
		GrantOne(AbilityClass);
	}

	// 配件能力：装备时把已安装配件声明的能力也授上（配件可能先于装备安装）
	for (const FFPSInstalledAttachment& Entry : InstalledAttachmentIDs)
	{
		if (const UFPSWeaponAttachmentData* const* Found = CachedAttachmentData.Find(Entry.Slot))
		{
			GrantAttachmentAbilities(Entry.Slot, *Found);
		}
	}
}

void AFPSWeaponBase::RemoveAbilities()
{
	// Only the server can remove abilities
	if (!HasAuthority())
	{
		return;
	}

	// 配件授予的能力一并撤销（清账 + 从 ASC 移除）
	{
		TArray<EFPSAttachmentSlotType> AttachmentSlots;
		AttachmentAbilityHandles.GetKeys(AttachmentSlots);
		for (const EFPSAttachmentSlotType Slot : AttachmentSlots)
		{
			RevokeAttachmentAbilities(Slot);
		}
	}

	UAbilitySystemComponent* ASC = GetOwnerASC();
	if (!ASC)
	{
		GrantedAbilityHandles.Empty();
		return;
	}

	for (const FGameplayAbilitySpecHandle& Handle : GrantedAbilityHandles)
	{
		ASC->ClearAbility(Handle);
	}
	GrantedAbilityHandles.Empty();
}

void AFPSWeaponBase::GrantAttachmentAbilities(EFPSAttachmentSlotType Slot, const UFPSWeaponAttachmentData* AttData)
{
	if (!HasAuthority() || !AttData)
	{
		return;
	}

	// 同一槽位先清旧账（幂等：重复安装 / 换件不重复授予）
	RevokeAttachmentAbilities(Slot);

	if (AttData->GrantedAbilities.IsEmpty())
	{
		return;
	}

	UAbilitySystemComponent* ASC = GetOwnerASC();
	if (!ASC)
	{
		// 还没装备（没有 Owner ASC）：装备时 GrantAbilities 会补授
		return;
	}

	TArray<FGameplayAbilitySpecHandle>& Handles = AttachmentAbilityHandles.FindOrAdd(Slot);
	for (const TSubclassOf<UFPSGameplayAbility>& AbilityClass : AttData->GrantedAbilities)
	{
		if (!AbilityClass)
		{
			continue;
		}

		FGameplayAbilitySpec Spec(AbilityClass, 1, INDEX_NONE, this);
		const FGameplayAbilitySpecHandle Handle = ASC->GiveAbility(Spec);
		Handles.Add(Handle);
		UE_LOG(LogTemp, Display, TEXT("[Attachment] 授予能力 %s（槽 %d）"),
			*GetNameSafe(AbilityClass.Get()), static_cast<int32>(Slot));
	}

	if (Handles.IsEmpty())
	{
		AttachmentAbilityHandles.Remove(Slot);
	}
}

void AFPSWeaponBase::RevokeAttachmentAbilities(EFPSAttachmentSlotType Slot)
{
	if (!HasAuthority())
	{
		return;
	}

	TArray<FGameplayAbilitySpecHandle> Handles;
	if (!AttachmentAbilityHandles.RemoveAndCopyValue(Slot, Handles))
	{
		return;
	}

	UAbilitySystemComponent* ASC = GetOwnerASC();
	if (!ASC)
	{
		// 账已清；ASC 不存在时能力随其消亡，无需逐个撤销
		return;
	}

	for (const FGameplayAbilitySpecHandle& Handle : Handles)
	{
		ASC->ClearAbility(Handle);
	}
	UE_LOG(LogTemp, Display, TEXT("[Attachment] 撤销槽 %d 的 %d 个能力"), static_cast<int32>(Slot), Handles.Num());
}

void AFPSWeaponBase::ResetFireCooldown()
{
	bCanFireAgain = true;
}

//-------------------------------------------------------------------
// Attachment System
//-------------------------------------------------------------------

bool AFPSWeaponBase::InstallAttachment(EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData* AttData)
{
	if (!AttData || Slot == EFPSAttachmentSlotType::None)
	{
		return false;
	}

	// Verify the slot is supported by this weapon
	if (!CanInstallAttachment(Slot))
	{
		return false;
	}

	// Verify the attachment is for the correct slot
	if (AttData->SlotType != Slot)
	{
		return false;
	}

	// Install (replaces any existing attachment in the slot silently)
	InstalledAttachmentIDs.RemoveAll([Slot](const FFPSInstalledAttachment& E){ return E.Slot == Slot; });
	FFPSInstalledAttachment Entry;
	Entry.Slot = Slot;
	Entry.AttachmentID = AttData->AttachmentID;
	InstalledAttachmentIDs.Add(Entry);
	CachedAttachmentData.Add(Slot, AttData);

	// 服务器：把配件声明的能力授给持有者（未装备时留到装备时补授）
	GrantAttachmentAbilities(Slot, AttData);

	// 通知订阅者（按槽粒度；客户端侧由 OnRep 广播）
	OnAttachmentsChanged.Broadcast(Slot);

	return true;
}

bool AFPSWeaponBase::RemoveAttachment(EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData*& OutData)
{
	OutData = nullptr;

	UFPSWeaponAttachmentData** Found = CachedAttachmentData.Find(Slot);
	if (!Found || !(*Found))
	{
		return false;
	}

	OutData = *Found;
	CachedAttachmentData.Remove(Slot);
	InstalledAttachmentIDs.RemoveAll([Slot](const FFPSInstalledAttachment& E){ return E.Slot == Slot; });

	// 撤销该配件授予的能力
	RevokeAttachmentAbilities(Slot);

	// 通知订阅者（按槽粒度；客户端侧由 OnRep 广播）
	OnAttachmentsChanged.Broadcast(Slot);

	return true;
}

bool AFPSWeaponBase::CanInstallAttachment(EFPSAttachmentSlotType Slot) const
{
	if (!WeaponData || Slot == EFPSAttachmentSlotType::None)
	{
		return false;
	}
	return WeaponData->SupportedAttachmentSlots.Contains(Slot);
}

UFPSWeaponAttachmentData* AFPSWeaponBase::GetAttachment(EFPSAttachmentSlotType Slot) const
{
	UFPSWeaponAttachmentData* const* Found = CachedAttachmentData.Find(Slot);
	return Found ? *Found : nullptr;
}

//-------------------------------------------------------------------
// Effective Stat Queries
//-------------------------------------------------------------------

float AFPSWeaponBase::GetEffectiveDamage() const
{
	if (!WeaponData)
	{
		return 0.f;
	}
	float Total = WeaponData->BaseDamage;
	for (const auto& Pair : CachedAttachmentData)
	{
		if (Pair.Value)
		{
			Total += Pair.Value->StatModifiers.DamageDelta;
		}
	}
	return FMath::Max(0.f, Total);
}

float AFPSWeaponBase::GetEffectiveReloadTime() const
{
	if (!WeaponData)
	{
		return 2.f;
	}
	float Total = WeaponData->ReloadTime;
	for (const auto& Pair : CachedAttachmentData)
	{
		if (Pair.Value)
		{
			Total += Pair.Value->StatModifiers.ReloadTimeDelta;
		}
	}
	return FMath::Max(0.1f, Total); // Minimum 0.1s to avoid timer issues
}

int32 AFPSWeaponBase::GetEffectiveMagazineSize() const
{
	if (!WeaponData)
	{
		return 1;
	}
	float Total = static_cast<float>(WeaponData->MagazineSize);
	for (const auto& Pair : CachedAttachmentData)
	{
		if (Pair.Value)
		{
			Total += Pair.Value->StatModifiers.MagazineSizeDelta;
		}
	}
	return FMath::Max(1, FMath::RoundToInt(Total));
}


