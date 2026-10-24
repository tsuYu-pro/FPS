// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "GameFramework/Actor.h"
#include "FPSWeaponTypes.h"
#include "FPSAttachmentTypes.h"
#include "GameplayTagContainer.h"
#include "Abilities/GameplayAbility.h"
#include "FPSWeaponBase.generated.h"

class UFPSWeaponDataAsset;
class UFPSWeaponAttachmentData;
class USkeletalMeshComponent;
class AFPSCharacter;
class UAbilitySystemComponent;
class UGameplayAbility;
class UFPSGameplayAbility;
struct FGameplayAbilitySpecHandle;

// Delegate for ammo changes
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnAmmoChangedDelegate, int32, CurrentMagazine, int32, CurrentReserve);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnWeaponStateChangedDelegate, EFPSWeaponState, NewState);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAttachmentsChangedDelegate, EFPSAttachmentSlotType, Slot);

/**
 * AFPSWeaponBase
 *
 * Base class for all weapons in the FPS project.
 * Handles weapon state, ammo, and integrates with GAS for abilities.
 * Includes network RPCs for multiplayer fire synchronization.
 */
UCLASS(Abstract, Blueprintable)
class FPS_API AFPSWeaponBase : public AActor
{
	GENERATED_BODY()

public:
	AFPSWeaponBase();

	//-------------------------------------------------------------------
	// Components
	//-------------------------------------------------------------------

	/** Weapon mesh component */
	UPROPERTY(VisibleAnywhere, BlueprintReadOnly, Category = "Components")
	USkeletalMeshComponent* WeaponMesh;

	//-------------------------------------------------------------------
	// Configuration
	//-------------------------------------------------------------------

	/** Weapon data asset */
	UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "Weapon")
	UFPSWeaponDataAsset* WeaponData;

	/** Applied after attaching to the character's right hand socket. Tune per weapon Blueprint. */
	UPROPERTY(EditDefaultsOnly, BlueprintReadWrite, Category = "Weapon|Attachment")
	FVector EquippedRelativeLocationOffset = FVector::ZeroVector;

	//-------------------------------------------------------------------
	// State
	//-------------------------------------------------------------------

	/** Current weapon state */
	UPROPERTY(BlueprintReadOnly, Category = "Weapon|State")
	EFPSWeaponState CurrentState = EFPSWeaponState::Idle;

	/** Current ammo info */
	UPROPERTY(BlueprintReadOnly, Category = "Weapon|State")
	FWeaponAmmoInfo AmmoInfo;

	/** Owning character */
	UPROPERTY(BlueprintReadOnly, Category = "Weapon|State")
	TWeakObjectPtr<AFPSCharacter> OwningCharacter;

	//-------------------------------------------------------------------
	// Delegates
	//-------------------------------------------------------------------

	/** Broadcast when ammo changes */
	UPROPERTY(BlueprintAssignable, Category = "Weapon|Events")
	FOnAmmoChangedDelegate OnAmmoChanged;

	/** Broadcast when weapon state changes */
	UPROPERTY(BlueprintAssignable, Category = "Weapon|Events")
	FOnWeaponStateChangedDelegate OnWeaponStateChanged;

	/** 配件状态变化（按槽粒度广播；订阅者应重读该槽或整枪状态） */
	UPROPERTY(BlueprintAssignable, Category = "Weapon|Events")
	FOnAttachmentsChangedDelegate OnAttachmentsChanged;

	//-------------------------------------------------------------------
	// Weapon Interface
	//-------------------------------------------------------------------

	/** Called when weapon is equipped */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void OnEquip(AFPSCharacter* NewOwner);

	/** Called when weapon is unequipped */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void OnUnequip();

	/** Try to fire the weapon */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual bool TryFire();

	/** Actually perform the fire action */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void Fire();

	/** Try to reload the weapon */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual bool TryReload();

	/** Actually perform the reload */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void Reload();

	/** Finish reload (called when reload animation completes) */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void FinishReload();

	/** Cancel reload */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void CancelReload();

	/** Melee attack */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	virtual void MeleeAttack();

	//-------------------------------------------------------------------
	// Network RPCs
	//-------------------------------------------------------------------

	/** Client requests server to fire */
	UFUNCTION(Server, Reliable, WithValidation)
	void ServerFire(FVector MuzzleLocation, FVector FireDirection);

	/** Broadcast fire effects to all clients */
	UFUNCTION(NetMulticast, Unreliable)
	void MulticastFireEffects(FVector MuzzleLocation);

	/** Play fire effects locally (muzzle flash, fire sound). Called on owning client as prediction and on server for listen-server player. */
	void PlayFireEffectsLocally(FVector MuzzleLocation);

	//-------------------------------------------------------------------
	// State Queries
	//-------------------------------------------------------------------

	/** Check if weapon can fire */
	UFUNCTION(BlueprintCallable, Category = "Weapon|State")
	virtual bool CanFire() const;

	/** Check if weapon can reload */
	UFUNCTION(BlueprintCallable, Category = "Weapon|State")
	virtual bool CanReload() const;

	/** Check if weapon is idle */
	UFUNCTION(BlueprintCallable, Category = "Weapon|State")
	bool IsIdle() const { return CurrentState == EFPSWeaponState::Idle; }

	/** Check if weapon is reloading */
	UFUNCTION(BlueprintCallable, Category = "Weapon|State")
	bool IsReloading() const { return CurrentState == EFPSWeaponState::Reloading; }

	/** Check if weapon is firing */
	UFUNCTION(BlueprintCallable, Category = "Weapon|State")
	bool IsFiring() const { return CurrentState == EFPSWeaponState::Firing; }

	//-------------------------------------------------------------------
	// Ammo Management
	//-------------------------------------------------------------------

	/** Add ammo to reserve */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Ammo")
	int32 AddAmmo(int32 Amount);

	/** Get current magazine count */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Ammo")
	int32 GetCurrentMagazine() const { return AmmoInfo.CurrentMagazine; }

	/** Get current reserve count */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Ammo")
	int32 GetCurrentReserve() const { return AmmoInfo.CurrentReserve; }

	/** Get magazine capacity */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Ammo")
	int32 GetMagazineCapacity() const;

	//-------------------------------------------------------------------
	// Utility
	//-------------------------------------------------------------------

	/** Get the muzzle location */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	FVector GetMuzzleLocation() const;

	/** Get the muzzle rotation */
	UFUNCTION(BlueprintCallable, Category = "Weapon")
	FRotator GetMuzzleRotation() const;

	/** Get fire direction with spread applied — Lua overrides this to apply recoil pattern */
	UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "Weapon")
	FVector GetFireDirectionWithSpread();
	virtual FVector GetFireDirectionWithSpread_Implementation();

	/** Called after each shot fires — Lua overrides to advance pattern index */
	UFUNCTION(BlueprintNativeEvent, BlueprintCallable, Category = "Weapon")
	void OnShotFired();
	virtual void OnShotFired_Implementation();

	/** Current position in the recoil pattern sequence, read/written by Lua */
	UPROPERTY(BlueprintReadWrite, Category = "Weapon|Ballistics")
	int32 CurrentPatternIndex = 0;

	/** Get the owner's ability system component */
	UFUNCTION(BlueprintCallable, Category = "Weapon|GAS")
	UAbilitySystemComponent* GetOwnerASC() const;

	//-------------------------------------------------------------------
	// Attachment System
	//-------------------------------------------------------------------

	/**
	 * Installed attachments: slot type → attachment ID.
	 * Replicated so clients see the mod state (for visual attachment meshes).
	 */
	UPROPERTY(ReplicatedUsing = OnRep_InstalledAttachments, BlueprintReadOnly, Category = "Weapon|Attachments")
	TArray<FFPSInstalledAttachment> InstalledAttachmentIDs;

	/** Runtime cache: slot type → attachment data asset (rebuilt on rep-notify on clients) */
	UPROPERTY()
	TMap<EFPSAttachmentSlotType, UFPSWeaponAttachmentData*> CachedAttachmentData;

	/** 按 InstalledAttachmentIDs 重建运行时缓存（OnRep / BeginPlay 驱动；经 AssetManager 主资产查找） */
	void RebuildAttachmentCache();

	/**
	 * Install an attachment into the given slot.
	 * If a different attachment is already installed, it is replaced.
	 * 外部系统请统一走 UFPSAttachmentService（阶段一约定：唯一入口）。
	 * @return true on success.
	 */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	bool InstallAttachment(EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData* AttData);

	/**
	 * Remove the attachment from the given slot.
	 * OutData receives the removed attachment data (nullptr if slot was empty).
	 * 外部系统请统一走 UFPSAttachmentService（阶段一约定：唯一入口）。
	 * @return true if an attachment was present.
	 */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	bool RemoveAttachment(EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData*& OutData);

	/** Check whether this weapon's data asset supports the given slot type */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	bool CanInstallAttachment(EFPSAttachmentSlotType Slot) const;

	/** Get the attachment data asset currently installed in a slot (nullptr if empty) */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	UFPSWeaponAttachmentData* GetAttachment(EFPSAttachmentSlotType Slot) const;

	/** Effective damage = WeaponData->BaseDamage + sum of all installed DamageDelta */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	float GetEffectiveDamage() const;

	/** Effective reload time (seconds) with attachment modifiers applied */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	float GetEffectiveReloadTime() const;

	/** Effective magazine size (rounds) with attachment modifiers applied */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	int32 GetEffectiveMagazineSize() const;

protected:
	virtual void BeginPlay() override;
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

	UFUNCTION()
	void OnRep_InstalledAttachments();

	/** Set weapon state and broadcast change */
	void SetWeaponState(EFPSWeaponState NewState);

	/**
	 * 在指定枪口位置 spawn 弹体（服务端/Standalone 权威路径）。
	 * Fire() 和 ServerFire_Implementation() 共用此逻辑。
	 */
	void SpawnProjectile(const FVector& MuzzleLocation);

	//-------------------------------------------------------------------
	// GAS Integration
	//-------------------------------------------------------------------

	/**
	 * Per-weapon ability list — configure in each child Blueprint.
	 * These are granted to the owning character's ASC on equip and
	 * revoked on unequip, in addition to the abilities declared in WeaponData.
	 */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Weapon|GAS")
	TArray<TSubclassOf<UFPSGameplayAbility>> WeaponAbilities;

	/** Granted ability handles (runtime, not replicated) */
	UPROPERTY()
	TArray<FGameplayAbilitySpecHandle> GrantedAbilityHandles;

	/** Grant weapon abilities to owner (server only) */
	virtual void GrantAbilities();

	/** Remove weapon abilities from owner (server only) */
	virtual void RemoveAbilities();

	/** 配件授予的能力句柄（按槽位记账；运行时数据，不复制） */
	TMap<EFPSAttachmentSlotType, TArray<FGameplayAbilitySpecHandle>> AttachmentAbilityHandles;

	/** 把某配件声明的能力授给持有者 ASC（仅服务器；未装备时留到装备时补授） */
	void GrantAttachmentAbilities(EFPSAttachmentSlotType Slot, const UFPSWeaponAttachmentData* AttData);

	/** 撤销某槽位配件授予的能力（仅服务器） */
	void RevokeAttachmentAbilities(EFPSAttachmentSlotType Slot);

	//-------------------------------------------------------------------
	// Timers
	//-------------------------------------------------------------------

	/** Timer handle for fire cooldown */
	FTimerHandle FireCooldownTimerHandle;

	/** Timer handle for reload */
	FTimerHandle ReloadTimerHandle;

	/** Can fire again (cooldown check) */
	bool bCanFireAgain = true;

	/** Reset fire cooldown */
	void ResetFireCooldown();

	/** Max allowed distance between client-reported muzzle and server muzzle */
	static constexpr float MaxMuzzlePositionError = 200.0f;

private:
	/** Name of muzzle socket */
	static const FName MuzzleSocketName;
};
