// Copyright Epic Games, Inc. All Rights Reserved.

#pragma once

#include "CoreMinimal.h"
#include "Blueprint/UserWidget.h"
#include "UnLuaInterface.h"
#include "UGCErrorRowWidget.generated.h"

/**
 * UGCErrorRowWidget.h（T16）
 *
 * 错误列表行控件的 C++ 基类。唯一职责：实现 IUnLuaInterface::GetModuleName，
 * 把 `WBP_UGCErrorRow` 绑到 Lua 模块 "System.UI.UGC.WBP_UGCErrorRow"。
 *
 * 为什么用 C++ 基类而不是在蓝图里实现接口：GetModuleName 是 BlueprintNativeEvent，
 * 在蓝图里实现就得到事件图里放「接口事件节点 + Return 节点」，那种图用代码生成又脆又难读；
 * 而 UnLua 的 ULuaModuleLocator 只要求 CDO 的类实现了接口（见
 * Plugins/UnLua/Source/UnLua/Private/LuaModuleLocator.cpp:36），基类实现完全等价。
 * 用法与项目里其它控件一致：资产 `Content/_UGC/UI/WBP_UGCErrorRow.uasset` 配上
 * `Content/Script/System/UI/UGC/WBP_UGCErrorRow.lua`。
 */
UCLASS(Blueprintable)
class FPS_API UUGCErrorRowWidget : public UUserWidget, public IUnLuaInterface
{
    GENERATED_BODY()

public:
    /** IUnLuaInterface：Lua 模块路径（相对 Content/Script，用点号分层） */
    virtual FString GetModuleName_Implementation() const override;
};
