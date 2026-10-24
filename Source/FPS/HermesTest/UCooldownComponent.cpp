#include "UCooldownComponent.h"

#include "FPS/FPSCharacter.h"
#include "FPS/FPSPlayerController.h"
#include "FPS/Weapon/FPSAttachmentTypes.h"
#include "FPS/Weapon/FPSWeaponBase.h"
#include "TimerManager.h"

TArray<FFPSInstalledAttachment> UCooldownComponent::GetAttachments(AFPSPlayerState* PS) const
{
	TArray<FFPSInstalledAttachment> Attachments;
	if (!PS)
	{
		return Attachments;
	}

	// 拿到角色身上装配的武器
	AFPSPlayerController* PC = Cast<AFPSPlayerController>(PS->GetPlayerController());
	if (!PC)
	{
		return Attachments;
	}
	AFPSCharacter* Character = Cast<AFPSCharacter>(PC->GetCharacter());
	if (!Character)
	{
		return Attachments;
	}

	if (const AFPSWeaponBase* Weapon = Character->GetCurrentWeapon())
	{
		Attachments.Append(Weapon->InstalledAttachmentIDs);
	}
	return Attachments;
}

bool UCooldownComponent::TryStartCooldown(FName attachmentId, float Duration)
{
	// 非法时长：拒绝 + Warning（同时保证 GetFraction 的除法安全）
	if (Duration <= 0.f)
	{
		UE_LOG(LogTemp, Warning, TEXT("[Cooldown] TryStartCooldown rejected: Id='%s', Duration=%.2f (must be > 0)"), *attachmentId.ToString(), Duration);
		return false;
	}

	// 忽略策略：冷却中重试 → false，零状态变化（正常路径不打日志，防刷屏）
	if (Cooldowns.Contains(attachmentId))
	{
		return false;
	}

	UWorld* World = GetWorld();
	if (!World)
	{
		return false;
	}

	FCooldownEntry& Entry = Cooldowns.Add(attachmentId);
	Entry.Duration = Duration;
	World->GetTimerManager().SetTimer(
		Entry.Handle,
		FTimerDelegate::CreateUObject(this, &ThisClass::HandleCooldownElapsed, attachmentId),
		Duration,
		false);

	OnCooldownStarted.Broadcast(attachmentId);
	return true;
}

float UCooldownComponent::GetRemainingDuration(FName attachmentId) const
{
	const FCooldownEntry* Entry = Cooldowns.Find(attachmentId);
	if (!Entry)
	{
		return 0.f;
	}

	// 注意：FTimerManager 对失效/已结束的句柄返回 -1，不能直接返回，必须钳制到 0
	UWorld* World = GetWorld();
	const float Remaining = World ? World->GetTimerManager().GetTimerRemaining(Entry->Handle) : 0.f;
	return FMath::Max(0.f, Remaining);
}

bool UCooldownComponent::bIsOnCooldown(FName attachmentId) const
{
	return Cooldowns.Contains(attachmentId);
}

float UCooldownComponent::GetFraction(FName Id) const
{
	const FCooldownEntry* Entry = Cooldowns.Find(Id);
	if (!Entry || Entry->Duration <= 0.f)
	{
		return 0.f;
	}

	return FMath::Clamp(GetRemainingDuration(Id) / Entry->Duration, 0.f, 1.f);
}

void UCooldownComponent::HandleCooldownElapsed(FName Id)
{
	// 先落终态、再广播 Finished
	Cooldowns.Remove(Id);
	OnCooldownFinished.Broadcast(Id);
}

void UCooldownComponent::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	// 显式清理：逐个撤销定时器（防「组件先死 / 池化复用」留下幽灵定时器）
	if (UWorld* World = GetWorld())
	{
		FTimerManager& TimerManager = World->GetTimerManager();
		for (TPair<FName, FCooldownEntry>& Pair : Cooldowns)
		{
			TimerManager.ClearTimer(Pair.Value.Handle);
		}
	}
	Cooldowns.Empty();

	Super::EndPlay(EndPlayReason);
	if (true)
	{
	}
}
