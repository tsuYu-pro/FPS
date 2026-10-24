// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Engine/DataAsset.h"
#include "FPSAttachmentTypes.h"
#include "FPSWeaponAttachmentData.generated.h"

class UStaticMesh;
class UTexture2D;
class UFPSGameplayAbility;

/**
 * UFPSWeaponAttachmentData
 *
 * Primary data asset describing a single weapon attachment (sight, muzzle device,
 * handguard, or magazine). Designers create one asset per attachment variant.
 *
 * Workflow:
 *  1. Create a UFPSWeaponAttachmentData asset in the editor.
 *  2. Set SlotType and StatModifiers.
 *  3. Set ItemDefID to match the row name in the item DataTable (so the inventory
 *     system can look up attachment data from an FInventoryItem).
 */
UCLASS(BlueprintType)
class FPS_API UFPSWeaponAttachmentData : public UPrimaryDataAsset
{
	GENERATED_BODY()

public:
	//-------------------------------------------------------------------
	// Identity
	//-------------------------------------------------------------------

	/** Unique identifier for this attachment */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Info")
	FName AttachmentID;

	/** Display name shown in UI */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Info")
	FText AttachmentName;

	/** Description shown in tooltip */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Info")
	FText Description;

	/** Which slot type this attachment occupies on a weapon */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Info")
	EFPSAttachmentSlotType SlotType = EFPSAttachmentSlotType::None;

	//-------------------------------------------------------------------
	// Stats
	//-------------------------------------------------------------------

	/** Additive modifiers applied to the weapon's base stats when installed */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Stats")
	FFPSAttachmentStatModifiers StatModifiers;

	//-------------------------------------------------------------------
	// Abilities
	//-------------------------------------------------------------------

	/** 装备在武器上时授予持有者 ASC 的能力（服务器端授予；卸下时撤销） */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Abilities")
	TArray<TSubclassOf<UFPSGameplayAbility>> GrantedAbilities;

	//-------------------------------------------------------------------
	// Visuals
	//-------------------------------------------------------------------

	/** 3D static mesh attached to the weapon when installed */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Visual")
	TSoftObjectPtr<UStaticMesh> AttachmentMesh;

	/** Icon displayed in inventory / mod UI */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Visual")
	TSoftObjectPtr<UTexture2D> Icon;

	//-------------------------------------------------------------------
	// Inventory Link
	//-------------------------------------------------------------------

	/** Row name in the item DataTable — used to map FInventoryItem ↔ attachment data */
	UPROPERTY(EditDefaultsOnly, BlueprintReadOnly, Category = "Attachment|Inventory")
	FName ItemDefID;

	// UPrimaryDataAsset interface
	virtual FPrimaryAssetId GetPrimaryAssetId() const override;
};
