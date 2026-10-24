// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Kismet/BlueprintFunctionLibrary.h"
#include "FPS/Weapon/FPSAttachmentTypes.h"
#include "FPSAttachmentService.generated.h"

class AFPSWeaponBase;
class UFPSWeaponAttachmentData;

/**
 * UFPSAttachmentService —— 配件装/卸的唯一推荐入口（阶段一约定，2026-10-08）
 *
 * 现阶段职责：策略守卫（服务器权威 / 空值）+ 转发到武器内部实现（逻辑照搬，行为不变）。
 * 后续（阶段二起）跨系统编排都收敛到这里：背包校验、事件扩散、交易锁、持久化。
 *
 * 新功能的接入方式约定：不要横穿 GAS / Inventory / Weapon / Player 四处拼接口，
 * 以“订阅者”身份监听 AFPSWeaponBase::OnAttachmentsChanged（按槽粒度广播）。
 *
 * 详见 Docs/knowledge/ATTACHMENT_ARCHITECTURE_AND_ROADMAP.md
 */
UCLASS()
class FPS_API UFPSAttachmentService : public UBlueprintFunctionLibrary
{
	GENERATED_BODY()

public:
	/** 安装配件（服务器权威入口）。成功时武器端广播 OnAttachmentsChanged。 */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	static bool InstallAttachment(AFPSWeaponBase* Weapon, EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData* AttData);

	/** 卸下配件（服务器权威入口）。OutData 返回被卸下的配件数据。 */
	UFUNCTION(BlueprintCallable, Category = "Weapon|Attachments")
	static bool RemoveAttachment(AFPSWeaponBase* Weapon, EFPSAttachmentSlotType Slot, UFPSWeaponAttachmentData*& OutData);
};
