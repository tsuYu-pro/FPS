// Copyright Epic Games, Inc. All Rights Reserved.

/**
 * UGCWidgetSetupCommands.cpp（T16 迁移工具，Editor-only）
 *
 * 用途：把「验证错误列表」需要的两个 UMG 结构一次性建好，且可重复执行：
 *   1. 新建行控件资产 `WBP_UGCErrorRow`（Border 根 + TextBlock 标签：根是 Border 才能在
 *      ScrollBox 里按内容自适应高度 —— CanvasPanel 根的控件 desired size 为 0，放进去会不可见）；
 *   2. 给 `WBP_UGCBlueprintEditor` 补一块默认隐藏的错误面板：
 *      USizeBox[w_error_panel] (高 150) → UBorder[w_error_border_bg] → UScrollBox[w_scroll_errors]，
 *      作为根 VerticalBox 的最后一个 Auto 子项插在画布下方。
 *
 * 为什么做成控制台命令：UMG 资产改动必须在编辑器里做，而 `WBP_UGCBlueprintEditor` 的根是 Border
 * （不是 CanvasPanel），UEEditorMCP 那一批 add_*_to_widget 动作都要求根是 CanvasPanel，用不上；
 * 命令方式可复现、幂等，也能在无头编辑器里重跑。
 *
 * 用法（无头）：
 *   UnrealEditor-Cmd.exe <project>.uproject -ExecCmds="UGC.SetupErrorListUI" -unattended -nosplash -NullRHI -log
 * 用法（编辑器内）：控制台输入 UGC.SetupErrorListUI
 *
 * 幂等：`w_error_panel` 已存在则跳过（不覆盖手工调整）；行控件已存在则只回填缺失的控件与命名。
 * 真正的列表填充与「点击定位到节点/引脚」逻辑在 Lua：
 *   Content/Script/System/UI/UGC/WBP_UGCBlueprintEditor.lua、
 *   Content/Script/System/UI/UGC/WBP_UGCErrorRow.lua、
 *   Content/Script/Gameplay/UGC/UGCErrorList.lua
 */

#include "CoreMinimal.h"

#if WITH_EDITOR

#include "WidgetBlueprint.h"
#include "WidgetBlueprintFactory.h"
#include "Blueprint/UserWidget.h"
#include "Blueprint/WidgetTree.h"
#include "Components/Border.h"
#include "Components/BorderSlot.h"
#include "Components/ScrollBox.h"
#include "Components/SizeBox.h"
#include "Components/TextBlock.h"
#include "Components/VerticalBox.h"
#include "Components/VerticalBoxSlot.h"
#include "AssetRegistry/AssetRegistryModule.h"
#include "HAL/IConsoleManager.h"
#include "Kismet2/BlueprintEditorUtils.h"
#include "Kismet2/KismetEditorUtilities.h"
#include "Misc/PackageName.h"
#include "UObject/Package.h"
#include "UObject/SavePackage.h"
#include "UGCErrorRowWidget.h"
#include "UnLuaInterface.h"

namespace
{
    const TCHAR* const UGCUIDir        = TEXT("/Game/_UGC/UI");
    const TCHAR* const RowAssetName    = TEXT("WBP_UGCErrorRow");
    const TCHAR* const EditorAssetName = TEXT("WBP_UGCBlueprintEditor");

    const TCHAR* const RowBorderName   = TEXT("w_border_bg");
    const TCHAR* const RowLabelName    = TEXT("w_text_label");
    const TCHAR* const PanelName       = TEXT("w_error_panel");
    const TCHAR* const PanelBorderName = TEXT("w_error_border_bg");
    const TCHAR* const ErrorListName   = TEXT("w_scroll_errors");

    /** 面板高度：错误条目可滚动，面板本身不参与画布拉伸 */
    constexpr float PanelHeight = 150.f;

    /** 汇总：与 UGCPrefabDevCommands 同风格，逐项 + 总计都要能在日志里读到 */
    struct FSetupReport
    {
        int32 Created   = 0;
        int32 BackFilled = 0;
        int32 Skipped   = 0;
        int32 Saved     = 0;
        int32 Failed    = 0;
        TArray<FString> Notes;

        void Note(const FString& In)
        {
            Notes.Add(In);
            UE_LOG(LogTemp, Display, TEXT("[UGCWidgetSetup] %s"), *In);
        }
    };

    UWidget* FindFirstOfClass(UWidget* Root, UClass* Class)
    {
        if (!Root)
        {
            return nullptr;
        }
        if (Root->IsA(Class))
        {
            return Root;
        }
        if (UPanelWidget* Panel = Cast<UPanelWidget>(Root))
        {
            const int32 Count = Panel->GetChildrenCount();
            for (int32 Index = 0; Index < Count; ++Index)
            {
                if (UWidget* Found = FindFirstOfClass(Panel->GetChildAt(Index), Class))
                {
                    return Found;
                }
            }
        }
        return nullptr;
    }

    bool SaveEditorAsset(UObject* Asset, FSetupReport& Report, const FString& What)
    {
        if (!Asset)
        {
            return false;
        }
        UPackage* Package = Asset->GetOutermost();
        const FString FileName = FPackageName::LongPackageNameToFilename(
            Package->GetName(), FPackageName::GetAssetPackageExtension());

        FSavePackageArgs SaveArgs;
        SaveArgs.TopLevelFlags = RF_Public | RF_Standalone;
        SaveArgs.SaveFlags     = SAVE_NoError;

        if (!UPackage::SavePackage(Package, Asset, *FileName, SaveArgs))
        {
            Report.Failed++;
            Report.Note(FString::Printf(TEXT("%s 保存失败：%s"), *What, *FileName));
            return false;
        }
        Report.Saved++;
        return true;
    }

    /** Lua 模块名的唯一来源是 C++ 基类（命令里不再各写一份） */
    FString GetRowLuaModuleName()
    {
        const UUGCErrorRowWidget* RowCDO = GetDefault<UUGCErrorRowWidget>();
        return RowCDO ? IUnLuaInterface::Execute_GetModuleName(RowCDO) : FString();
    }

    /**
     * 把行控件指到提供 Lua 绑定的 C++ 基类（UUGCErrorRowWidget）上。
     * 为什么必须做：UnLua 的 ULuaModuleLocator 只在类实现了 UnLuaInterface 时才去找 Lua 模块
     * （Plugins/UnLua/Source/UnLua/Private/LuaModuleLocator.cpp:36），否则 CDO 上根本没有 Lua 方法 ——
     * 行控件会「建得出来、SetErrorRow 是 nil」，列表渲染 0 行（2026-09-15 PIE 实测）。
     * 接口由 C++ 基类实现（见 UGCErrorRowWidget.h 的说明），所以这里只换父类；
     * 若蓝图侧还留着自己那份 UnLuaInterface，要摘掉 —— 空实现会盖住基类的 GetModuleName。
     */
    bool BindRowWidgetToLuaBase(UWidgetBlueprint* Blueprint, FSetupReport& Report)
    {
        if (!Blueprint)
        {
            return false;
        }

        bool bChanged = false;

        UClass* LuaBaseClass = UUGCErrorRowWidget::StaticClass();
        if (Blueprint->ParentClass != LuaBaseClass)
        {
            Blueprint->ParentClass = LuaBaseClass;
            bChanged = true;
            Report.Note(FString::Printf(TEXT("%s: 父类改为 %s（提供 Lua 绑定）"),
                *Blueprint->GetName(), *LuaBaseClass->GetName()));
        }

        // 早期版本在这里给蓝图实现过 UnLuaInterface：留着会让生成类用空实现盖住 C++ 基类
        if (UClass* InterfaceClass = UUnLuaInterface::StaticClass())
        {
            const bool bHasInterface = Blueprint->ImplementedInterfaces.ContainsByPredicate(
                [InterfaceClass](const FBPInterfaceDescription& Description)
                {
                    return Description.Interface == InterfaceClass;
                });
            if (bHasInterface)
            {
                FBlueprintEditorUtils::RemoveInterface(Blueprint, InterfaceClass->GetClassPathName());
                bChanged = true;
                Report.Note(FString::Printf(TEXT("%s: 摘掉蓝图侧 UnLuaInterface（改由 C++ 基类提供）"),
                    *Blueprint->GetName()));
            }
        }

        if (bChanged)
        {
            Report.BackFilled++;
            Report.Note(FString::Printf(TEXT("%s: Lua 模块 = %s"), *Blueprint->GetName(), *GetRowLuaModuleName()));
        }
        else
        {
            Report.Skipped++;
            Report.Note(FString::Printf(TEXT("%s: Lua 绑定已就绪（%s），未改动"),
                *Blueprint->GetName(), *GetRowLuaModuleName()));
        }
        return true;
    }

    /** 行控件：Border 根 + TextBlock 标签（ScrollBox 里靠内容自适应高度） */
    UWidgetBlueprint* EnsureErrorRowWidget(FSetupReport& Report)
    {
        const FString PackageName = FString(UGCUIDir) / RowAssetName;
        UWidgetBlueprint* Blueprint = FindObject<UWidgetBlueprint>(nullptr, *(PackageName + TEXT(".") + RowAssetName));
        if (!Blueprint)
        {
            Blueprint = LoadObject<UWidgetBlueprint>(nullptr, *(PackageName + TEXT(".") + RowAssetName));
        }

        if (Blueprint)
        {
            // 已存在：只回填缺失部件，不动已存在的
            Report.Skipped++;
            Report.Note(FString::Printf(TEXT("%s 已存在，跳过创建（只做缺失部件回填）"), RowAssetName));
        }
        else
        {
            UPackage* Package = CreatePackage(*PackageName);
            UWidgetBlueprintFactory* Factory = NewObject<UWidgetBlueprintFactory>();
            Factory->ParentClass = UUserWidget::StaticClass();

            UObject* NewAsset = Factory->FactoryCreateNew(
                UWidgetBlueprint::StaticClass(), Package, FName(RowAssetName),
                RF_Public | RF_Standalone, nullptr, GWarn);
            Blueprint = Cast<UWidgetBlueprint>(NewAsset);
            if (!Blueprint)
            {
                Report.Failed++;
                Report.Note(FString::Printf(TEXT("%s 创建失败"), RowAssetName));
                return nullptr;
            }
            FAssetRegistryModule::AssetCreated(Blueprint);
            Report.Created++;
            Report.Note(FString::Printf(TEXT("%s 已创建"), RowAssetName));
        }

        UWidgetTree* Tree = Blueprint->WidgetTree;
        if (!Tree)
        {
            Report.Failed++;
            Report.Note(FString::Printf(TEXT("%s 没有 WidgetTree"), RowAssetName));
            return nullptr;
        }

        UBorder* RootBorder = Cast<UBorder>(Tree->RootWidget);
        if (!RootBorder)
        {
            RootBorder = Tree->ConstructWidget<UBorder>(UBorder::StaticClass(), FName(RowBorderName));
            RootBorder->SetBrushColor(FLinearColor(0.09f, 0.09f, 0.09f, 0.92f));
            RootBorder->SetPadding(FMargin(10.f, 6.f, 10.f, 6.f));
            RootBorder->bIsVariable = true;
            Tree->RootWidget = RootBorder;
            Report.BackFilled++;
            Report.Note(FString::Printf(TEXT("%s: 回填根 Border(%s)"), RowAssetName, RowBorderName));
        }
        else if (RootBorder->GetFName() != FName(RowBorderName))
        {
            RootBorder->Rename(*FString(RowBorderName), Tree);
        }

        if (!Tree->FindWidget(FName(RowLabelName)))
        {
            UTextBlock* Label = Tree->ConstructWidget<UTextBlock>(UTextBlock::StaticClass(), FName(RowLabelName));
            Label->SetText(FText::FromString(TEXT("—")));
            Label->SetAutoWrapText(true);
            FSlateFontInfo Font = Label->GetFont();
            Font.Size = 12;
            Label->SetFont(Font);
            Label->SetColorAndOpacity(FSlateColor(FLinearColor(0.88f, 0.88f, 0.88f, 1.f)));
            Label->bIsVariable = true;
            RootBorder->AddChild(Label);
            Report.BackFilled++;
            Report.Note(FString::Printf(TEXT("%s: 回填标签 TextBlock(%s)"), RowAssetName, RowLabelName));
        }

        // UnLua 绑定：没有它，Lua 侧的 SetErrorRow / 点击回调全是 nil（列表渲染不出来）
        BindRowWidgetToLuaBase(Blueprint, Report);

        FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint);
        FKismetEditorUtilities::CompileBlueprint(Blueprint);
        SaveEditorAsset(Blueprint, Report, RowAssetName);
        return Blueprint;
    }

    /** 给蓝图编辑器控件补一块默认隐藏的错误面板（幂等） */
    UWidgetBlueprint* EnsureErrorPanelInEditorWidget(FSetupReport& Report)
    {
        const FString PackageName = FString(UGCUIDir) / EditorAssetName;
        UWidgetBlueprint* Blueprint = LoadObject<UWidgetBlueprint>(nullptr, *(PackageName + TEXT(".") + EditorAssetName));
        if (!Blueprint)
        {
            Report.Failed++;
            Report.Note(FString::Printf(TEXT("找不到 %s，无法补充错误面板"), EditorAssetName));
            return nullptr;
        }

        UWidgetTree* Tree = Blueprint->WidgetTree;
        if (!Tree)
        {
            Report.Failed++;
            Report.Note(FString::Printf(TEXT("%s 没有 WidgetTree"), EditorAssetName));
            return nullptr;
        }

        if (Tree->FindWidget(FName(PanelName)))
        {
            Report.Skipped++;
            Report.Note(FString::Printf(TEXT("%s 已有 %s，跳过（不覆盖手工调整）"), EditorAssetName, PanelName));
            return Blueprint;
        }

        UVerticalBox* TopBox = Cast<UVerticalBox>(FindFirstOfClass(Tree->RootWidget, UVerticalBox::StaticClass()));
        if (!TopBox)
        {
            Report.Failed++;
            Report.Note(FString::Printf(TEXT("%s 里找不到根 VerticalBox，无法插入错误面板"), EditorAssetName));
            return nullptr;
        }

        USizeBox* Panel = Tree->ConstructWidget<USizeBox>(USizeBox::StaticClass(), FName(PanelName));
        Panel->SetHeightOverride(PanelHeight);
        Panel->bIsVariable = true;
        Panel->SetVisibility(ESlateVisibility::Collapsed);   // 默认隐藏：验证失败时由 Lua 打开

        UBorder* PanelBorder = Tree->ConstructWidget<UBorder>(UBorder::StaticClass(), FName(PanelBorderName));
        PanelBorder->SetBrushColor(FLinearColor(0.12f, 0.03f, 0.03f, 0.94f));
        PanelBorder->SetPadding(FMargin(8.f, 6.f, 8.f, 6.f));
        PanelBorder->bIsVariable = true;

        UScrollBox* ErrorList = Tree->ConstructWidget<UScrollBox>(UScrollBox::StaticClass(), FName(ErrorListName));
        ErrorList->SetOrientation(EOrientation::Orient_Vertical);
        ErrorList->bIsVariable = true;

        PanelBorder->AddChild(ErrorList);
        Panel->AddChild(PanelBorder);

        UVerticalBoxSlot* Slot = TopBox->AddChildToVerticalBox(Panel);
        if (Slot)
        {
            Slot->SetSize(FSlateChildSize(ESlateSizeRule::Automatic));
            Slot->SetPadding(FMargin(0.f, 4.f, 0.f, 0.f));
        }

        FBlueprintEditorUtils::MarkBlueprintAsStructurallyModified(Blueprint);
        FKismetEditorUtilities::CompileBlueprint(Blueprint);
        SaveEditorAsset(Blueprint, Report, EditorAssetName);
        Report.BackFilled++;
        Report.Note(FString::Printf(TEXT("%s: 已插入 %s → %s → %s（高 %.0f，默认折叠）"),
            EditorAssetName, PanelName, PanelBorderName, ErrorListName, PanelHeight));
        return Blueprint;
    }

    void SetupErrorListUI()
    {
        FSetupReport Report;
        EnsureErrorRowWidget(Report);
        EnsureErrorPanelInEditorWidget(Report);

        UE_LOG(LogTemp, Display,
            TEXT("[UGCWidgetSetup] summary created=%d backfilled=%d skipped=%d saved=%d failed=%d"),
            Report.Created, Report.BackFilled, Report.Skipped, Report.Saved, Report.Failed);
    }

    FAutoConsoleCommand GUGCSetupErrorListCommand(
        TEXT("UGC.SetupErrorListUI"),
        TEXT("确保 WBP_UGCErrorRow 与 WBP_UGCBlueprintEditor 的错误列表面板存在（幂等，可重复执行）"),
        FConsoleCommandDelegate::CreateStatic(&SetupErrorListUI));
}

#endif // WITH_EDITOR
