// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "FPSAttachmentTypes.h"
#include "FPS/Inventory/InventoryTypes.h"
#include "FPSWeaponSlotComponent.generated.h"

class AFPSWeaponBase;
class AFPSCharacter;

DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnActiveWeaponChanged, EFPSWeaponSlot, OldSlot, EFPSWeaponSlot, NewSlot);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnWeaponSlotChanged, EFPSWeaponSlot, Slot);

/**
 * UFPSWeaponSlotComponent
 *
 * Manages three weapon carry slots (Primary1, Primary2, Pistol) for a character.
 *
 * Design:
 *  - SlotWeapons[0..2] maps to Primary1/Primary2/Pistol.
 *  - Weapon actors are spawned server-side and replicate via actor replication.
 *  - ActiveSlot is replicated so clients show/hide the correct weapon.
 *  - Server RPCs (ServerSwitchToSlot, ServerCycleWeapon) allow clients to request
 *    slot changes.
 */
UCLASS(ClassGroup = (Custom), meta = (BlueprintSpawnableComponent))
class FPS_API UFPSWeaponSlotComponent : public UActorComponent
{
	GENERATED_BODY()

public:
	UFPSWeaponSlotComponent();

	//-------------------------------------------------------------------
	// Replicated State
	//-------------------------------------------------------------------

	/**
	 * Spawned weapon actors for each slot (index 0 = Primary1, 1 = Primary2, 2 = Pistol).
	 * Each weapon actor replicates itself; this array is the slot ↔ actor mapping.
	 */
	UPROPERTY(ReplicatedUsing = OnRep_SlotWeapons, BlueprintReadOnly, Category = "WeaponSlot")
	TArray<AFPSWeaponBase*> SlotWeapons;

	/** Inventory item instance for each slot (for persistence / returning to inventory) */
	UPROPERTY(Replicated, BlueprintReadOnly, Category = "WeaponSlot")
	TArray<FInventoryItem> SlotInventoryItems;

	/** Currently equipped slot */
	UPROPERTY(ReplicatedUsing = OnRep_ActiveSlot, BlueprintReadOnly, Category = "WeaponSlot")
	EFPSWeaponSlot ActiveSlot = EFPSWeaponSlot::None;

	//-------------------------------------------------------------------
	// Delegates
	//-------------------------------------------------------------------

	UPROPERTY(BlueprintAssignable, Category = "WeaponSlot|Events")
	FOnActiveWeaponChanged OnActiveWeaponChanged;

	UPROPERTY(BlueprintAssignable, Category = "WeaponSlot|Events")
	FOnWeaponSlotChanged OnWeaponSlotChanged;

	//-------------------------------------------------------------------
	// Public Interface
	//-------------------------------------------------------------------

	/**
	 * Place a weapon into a slot (server-only).
	 * Spawns the weapon actor, stores the inventory item reference.
	 * Auto-equips if no slot is currently active.
	 * @return true if successful.
	 */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	bool SetWeaponInSlot(EFPSWeaponSlot Slot, const FInventoryItem& WeaponItem,
	                     TSubclassOf<AFPSWeaponBase> WeaponClass);

	/**
	 * Remove weapon from slot (server-only).
	 * Returns the inventory item via OutItem.
	 * @return true if slot was occupied.
	 */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	bool RemoveWeaponFromSlot(EFPSWeaponSlot Slot, FInventoryItem& OutItem);

	/** Switch the active weapon to a specific slot */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	void SwitchToSlot(EFPSWeaponSlot Slot);

	/** Server RPC: client requests a slot switch */
	UFUNCTION(Server, Reliable)
	void ServerSwitchToSlot(EFPSWeaponSlot Slot);

	/** Cycle to the next occupied slot */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	void CycleToNextSlot();

	/** Server RPC: client requests cycle */
	UFUNCTION(Server, Reliable)
	void ServerCycleToNextSlot();

	/** Get the currently active weapon actor */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	AFPSWeaponBase* GetActiveWeapon() const;

	/** Get weapon actor in a specific slot */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	AFPSWeaponBase* GetWeaponInSlot(EFPSWeaponSlot Slot) const;
	
	/** Check if a slot has a weapon */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	bool IsSlotOccupied(EFPSWeaponSlot Slot) const;

	/**
	 * Find the first empty slot appropriate for a weapon class.
	 * Pistols (bIsPistol = true in WeaponData) only go to Pistol slot.
	 * Primary weapons try Primary1 then Primary2.
	 * Returns None if no suitable slot is free.
	 */
	UFUNCTION(BlueprintCallable, Category = "WeaponSlot")
	EFPSWeaponSlot FindEmptySlotForWeapon(TSubclassOf<AFPSWeaponBase> WeaponClass) const;

	// UActorComponent interface
	virtual void GetLifetimeReplicatedProps(TArray<FLifetimeProperty>& OutLifetimeProps) const override;

protected:
	virtual void BeginPlay() override;

	/** Convert slot enum → array index [0, 2], returns INDEX_NONE for None */
	static int32 SlotToIndex(EFPSWeaponSlot Slot);

	/** Convert array index [0, 2] → slot enum */
	static EFPSWeaponSlot IndexToSlot(int32 Index);

	/** Spawn a weapon actor attached to the owning character (server-only) */
	AFPSWeaponBase* SpawnWeaponActor(TSubclassOf<AFPSWeaponBase> WeaponClass);

	/** Execute the equip transition: unequip old, equip new, attach mesh */
	void PerformSwitchToSlot(EFPSWeaponSlot NewSlot);

	/** Show or hide a weapon actor */
	static void SetWeaponVisible(AFPSWeaponBase* Weapon, bool bVisible);

	UFUNCTION()
	void OnRep_SlotWeapons();

	UFUNCTION()
	void OnRep_ActiveSlot();
};
