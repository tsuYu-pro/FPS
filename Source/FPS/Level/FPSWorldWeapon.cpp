// Copyright Epic Games, Inc. All Rights Reserved.

#include "FPSWorldWeapon.h"
#include "FPS/FPSCharacter.h"
#include "FPS/Weapon/FPSWeaponSlotComponent.h"
#include "FPS/Weapon/FPSWeaponBase.h"
#include "FPS/Weapon/FPSAttachmentService.h"
#include "FPS/Weapon/FPSWeaponAttachmentData.h"
#include "FPS/Inventory/Public/InventoryGridComponent.h"
#include "Components/StaticMeshComponent.h"
#include "Components/SphereComponent.h"
#include "FPS/Inventory/InventoryTypes.h"

AFPSWorldWeapon::AFPSWorldWeapon()
{
	PrimaryActorTick.bCanEverTick = false;
	bReplicates = true;

	// Root — static mesh showing the weapon on the ground
	WeaponMesh = CreateDefaultSubobject<UStaticMeshComponent>(TEXT("WeaponMesh"));
	RootComponent = WeaponMesh;
	WeaponMesh->SetCollisionEnabled(ECollisionEnabled::QueryAndPhysics);
	WeaponMesh->SetSimulatePhysics(false);

	// Interaction trigger sphere (radius 150 units)
	InteractionSphere = CreateDefaultSubobject<USphereComponent>(TEXT("InteractionSphere"));
	InteractionSphere->SetupAttachment(RootComponent);
	InteractionSphere->SetSphereRadius(150.f);
	InteractionSphere->SetCollisionEnabled(ECollisionEnabled::QueryOnly);
	InteractionSphere->SetCollisionResponseToAllChannels(ECR_Ignore);
	InteractionSphere->SetCollisionResponseToChannel(ECC_Pawn, ECR_Overlap);
}

void AFPSWorldWeapon::BeginPlay()
{
	Super::BeginPlay();

	if (HasAuthority())
	{
		InteractionSphere->OnComponentBeginOverlap.AddDynamic(this, &AFPSWorldWeapon::OnOverlapBegin);
		InteractionSphere->OnComponentEndOverlap.AddDynamic(this, &AFPSWorldWeapon::OnOverlapEnd);
	}
}

//-------------------------------------------------------------------
// Overlap Events (server-side proximity detection)
//-------------------------------------------------------------------

void AFPSWorldWeapon::OnOverlapBegin(UPrimitiveComponent* /*OverlappedComp*/, AActor* OtherActor,
                                     UPrimitiveComponent* /*OtherComp*/, int32 /*OtherBodyIndex*/,
                                     bool /*bFromSweep*/, const FHitResult& /*SweepResult*/)
{
	// Visual/audio feedback hook point — blueprint can bind to show pickup prompt
	// Actual interaction is triggered by the player pressing E via ServerInteract
}

void AFPSWorldWeapon::OnOverlapEnd(UPrimitiveComponent* /*OverlappedComp*/, AActor* OtherActor,
                                   UPrimitiveComponent* /*OtherComp*/, int32 /*OtherBodyIndex*/)
{
	// Hide pickup prompt if it was shown
}

//-------------------------------------------------------------------
// Interaction
//-------------------------------------------------------------------

void AFPSWorldWeapon::ServerInteract_Implementation(AFPSCharacter* Interactor)
{
	if (!bAvailable || !Interactor || !WeaponActorClass)
	{
		return;
	}

	// Mark unavailable immediately to prevent double-pickup
	bAvailable = false;

	UFPSWeaponSlotComponent* SlotComp =
		Interactor->FindComponentByClass<UFPSWeaponSlotComponent>();

	bool bPickedUp = false;

	if (SlotComp)
	{
		// Find an appropriate empty slot
		EFPSWeaponSlot EmptySlot = SlotComp->FindEmptySlotForWeapon(WeaponActorClass);
		if (EmptySlot != EFPSWeaponSlot::None)
		{
			// Build a minimal inventory item to track the weapon instance
			FInventoryItem WeaponItem;
			WeaponItem.ItemDefID = WeaponItemDefID;

			bPickedUp = SlotComp->SetWeaponInSlot(EmptySlot, WeaponItem, WeaponActorClass);

			// Install pre-configured attachments on the new weapon actor
			if (bPickedUp && !PreInstalledAttachments.IsEmpty())
			{
				if (AFPSWeaponBase* SpawnedWeapon = SlotComp->GetWeaponInSlot(EmptySlot))
				{
					for (const auto& Pair : PreInstalledAttachments)
					{
						if (Pair.Value)
						{
							// 统一走配件服务入口（阶段一约定）
							UFPSAttachmentService::InstallAttachment(SpawnedWeapon, Pair.Key, Pair.Value);
						}
					}
				}
			}
		}
	}

	// Fallback: try to add to inventory grid
	if (!bPickedUp)
	{
		if (UInventoryGridComponent* InventoryComp =
			Interactor->FindComponentByClass<UInventoryGridComponent>())
		{
			FInventoryItem WeaponItem;
			WeaponItem.ItemDefID = WeaponItemDefID;

			// Find first available position (0,0 fallback — inventory component handles overlap check)
			bPickedUp = InventoryComp->AddItem(WeaponItem, FIntPoint(0, 0), false);
		}
	}

	if (bPickedUp)
	{
		Destroy(); // Replicated to clients
	}
	else
	{
		// Nothing worked — restore availability
		bAvailable = true;
	}
}
