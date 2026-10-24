// Copyright Epic Games, Inc. All Rights Reserved.

#include "FPSAttachmentService.h"
#include "FPS/Weapon/FPSWeaponBase.h"
#include "FPS/Weapon/FPSWeaponAttachmentData.h"

bool UFPSAttachmentService::InstallAttachment(AFPSWeaponBase* Weapon, EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData* AttData)
{
	if (!IsValid(Weapon) || Slot == EFPSAttachmentSlotType::None || !IsValid(AttData))
	{
		return false;
	}

	if (!Weapon->HasAuthority())
	{
		UE_LOG(LogTemp, Warning, TEXT("[AttachmentService] InstallAttachment 被拒绝：非服务器权威（武器 %s）"), *GetNameSafe(Weapon));
		return false;
	}

	// 阶段一：逻辑照搬武器自身的实现；阶段二起，跨系统编排（背包校验 / 事件扩散 / 交易锁）上移到本服务
	return Weapon->InstallAttachment(Slot, AttData);
}

bool UFPSAttachmentService::RemoveAttachment(AFPSWeaponBase* Weapon, EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData*& OutData)
{
	OutData = nullptr;

	if (!IsValid(Weapon) || Slot == EFPSAttachmentSlotType::None)
	{
		return false;
	}

	if (!Weapon->HasAuthority())
	{
		UE_LOG(LogTemp, Warning, TEXT("[AttachmentService] RemoveAttachment 被拒绝：非服务器权威（武器 %s）"), *GetNameSafe(Weapon));
		return false;
	}

	// 阶段一：逻辑照搬（同上）
	return Weapon->RemoveAttachment(Slot, OutData);
}
