// Copyright Epic Games, Inc. All Rights Reserved.

#include "GA_AttachmentTest.h"

UGA_AttachmentTest::UGA_AttachmentTest()
{
	// 纯标记能力：不接输入；功能配件的能力应当是服务器权威的
	InstancingPolicy = EGameplayAbilityInstancingPolicy::InstancedPerActor;
	ActivationPolicy = EFPSAbilityActivationPolicy::OnInputTriggered;
	NetExecutionPolicy = EGameplayAbilityNetExecutionPolicy::ServerOnly;
}
