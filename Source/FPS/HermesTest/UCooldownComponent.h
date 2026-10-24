#pragma once
#include "CoreMinimal.h"
#include "Components/ActorComponent.h"
#include "Engine/TimerHandle.h"
#include "FPS/Team/FPSPlayerState.h"
#include "UCooldownComponent.generated.h"

struct FFPSInstalledAttachment;

namespace CooldownIds
{
	static const FName Flashlight(TEXT("Flashlight"));
	static const FName LaserPointer(TEXT("LaserPointer"));
}

/** 冷却事件（开始 / 结束共用一套签名）：参数为冷却 Id */
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnCooldownEvent, FName, CooldownId);

USTRUCT()
struct FCooldownEntry
{
	GENERATED_BODY()
	FTimerHandle Handle;
	float Duration = 0.f;
};

// 这个组件挂给Player，查询Player手里的所有配件，然后记录CD;

UCLASS(meta = (BlueprintSpawnableComponent))
class FPS_API UCooldownComponent : public UActorComponent
{
	GENERATED_BODY()

public:
	// 拿到Owner Player身上的所有配件ID;
	TArray<FFPSInstalledAttachment> GetAttachments(AFPSPlayerState* PS) const;

	// 进入冷却：就绪→true（广播 OnCooldownStarted）；冷却中→false（零状态变化）；Duration<=0→false+Warning
	UFUNCTION(BlueprintCallable, Category = "Cooldown")
	bool TryStartCooldown(FName attachmentId, float Duration);

	// 查询：冷却中 → 剩余秒数(>0)；否则 → 0
	UFUNCTION(BlueprintPure, Category = "Cooldown")
	float GetRemainingDuration(FName attachmentId) const;

	// true 冷却中 ; false 未知Id
	UFUNCTION(BlueprintPure, Category = "Cooldown")
	bool bIsOnCooldown(FName attachmentId) const;

	// 冷却中 → (0,1]（1 = 刚按下）；否则 → 0
	UFUNCTION(BlueprintPure, Category = "Cooldown")
	float GetFraction(FName Id) const;

	/** 从无到有，恰好一次 */
	UPROPERTY(BlueprintAssignable, Category = "Cooldown")
	FOnCooldownEvent OnCooldownStarted;

	/** 从有到无，恰好一次 */
	UPROPERTY(BlueprintAssignable, Category = "Cooldown")
	FOnCooldownEvent OnCooldownFinished;

	// 销毁后清空
	virtual void EndPlay(const EEndPlayReason::Type EndPlayReason) override;

private:
	// 到期回调：先移除条目、再广播（保证回调里查询到的已是终态）
	void HandleCooldownElapsed(FName Id);

	UPROPERTY()
	TMap<FName, FCooldownEntry> Cooldowns;
};
