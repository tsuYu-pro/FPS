// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "FPS/GAS/FPSGameplayAbility.h"
#include "GA_AttachmentTest.generated.h"

/**
 * UGA_AttachmentTest
 *
 * 调试用标记能力：没有玩法逻辑，专门用于验证「配件基类」的能力授予/撤销链路——
 * 控制台命令 FPS.AttachmentTest 把它挂在临时测试配件上，
 * 检查持有者 ASC 的技能表在安装时 +1、卸下时 -1。
 *
 * 后续做真实功能配件时，把配件的 GrantedAbilities 换成各自的 GA 即可；这个类只是测试件。
 */
UCLASS()
class FPS_API UGA_AttachmentTest : public UFPSGameplayAbility
{
	GENERATED_BODY()

public:
	UGA_AttachmentTest();
};
