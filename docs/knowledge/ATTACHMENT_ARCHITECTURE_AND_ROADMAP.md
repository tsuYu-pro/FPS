# 配件架构诊断与演进路线（Attachment Architecture & Roadmap）

- 状态：阶段一已落地（2026-10-08）
- 基线：UE 5.4；代码锚点为当日工作树（含 10-07/08 的配件 GAS 能力改动）
- 证据分级：`实测` = 本次构建/代码验证；`锚点` = 当前代码位置；外部结论 = 调研摘要（见 §7）

## 0. 结论先行

- 「新功能要横穿 GAS / Inventory / Player / Weapon 四个系统拿接口」的根因不是"系统多"，而是三个具体问题：
  **多副本无总账 / 变更无单一入口 / 状态无家**（§1）。
- 方向三句话：**域界重划**（物品=账本、GAS=执行、表现=订阅）、**单入口事务**、**实例身份**（§3）。
- 路线：阶段一（已落地，§4）→ 阶段二（状态归位）→ 阶段三（物品树化）。
- 度量判据：好的收口让新功能从"改 4 处"变成"订阅 1 处"。

## 1. 现状诊断（三个病，附锚点）

### 1.1 同一事实、多处副本、没有总账

"配件在不在、是什么"目前有多份副本：

| 副本 | 位置 | 说明 |
| --- | --- | --- |
| `InstalledAttachmentIDs` | `FPSWeaponBase.h` | 复制数组（网络真相：服务器写、客户端读） |
| `CachedAttachmentData` | `FPSWeaponBase.h` | 运行时缓存（槽 → 数据资产） |
| `AttachmentAbilityHandles` | `FPSWeaponBase.h`（protected） | GAS 借据（SpecHandle × 槽） |
| 策划数据资产 | `UFPSWeaponAttachmentData` | 声明数据（能力/属性加成） |
| （背包侧预留） | `FInventoryItem.InstanceID` | 配件作为独立物品时的身份 |

副本本身是合法的（复制/缓存都需要）；病在**没有"谁说了算"**。典型症状（阶段一修复前）：
`OnRep_InstalledAttachments` 只 `Empty()` 缓存、不重建 —— 客户端 `GetAttachment()` 返回空，
有效属性（伤害/弹匣/装弹时间）吃不到配件加成。

### 1.2 变更没有单一入口

装/卸在武器（`InstallAttachment` / `RemoveAttachment`）；"补授能力"在装备流程
（`OnEquip → GrantAbilities`）；拾取/交易将来会在背包侧；复制在 OnRep。
→ 新功能必须先把这些路径全部梳理一遍——这就是"横穿四个系统"的真实来源。
**是事务散，不是系统多。**

### 1.3 状态没有家

次数/开关/冷却（如爆闪手电筒）既不是 GAS attribute、也不在 `FInventoryItem` 里。
没有家的状态会被各系统"临时收养"，任何一次缓存重建/换装/池化就丢。

**评估尺子（新功能落地前先量）**：① 同一事实几份副本、谁是真？② 变更入口有几个？
③ 状态有没有家？④ 依赖方向（依赖稳定抽象 or 易变内部）？⑤ 复制/存档/重建/池化时谁活谁死？

## 2. 公允评估：GAS 复用的边界

现有做法的"好处"是真的，但要拆成两半看：

- **用 GAS 执行**（效果/能力/属性/标签结算、复制）→ 正确，继续复用，这是白捡的成熟设施；
- **让 GAS 记账**（"哪个配件装在哪把枪"由 `AttachmentAbilityHandles` 表达）→ 危险：
  `FGameplayAbilitySpecHandle` 是**运行时借据**，不是**产权证**；"装备时补授 / ASC 不存在时账已清"这类补丁感正是借据当产权证的产物。

一句话：**框架可以执行，不应该记账。**

## 3. 方向（第一性，不依赖外部参考）

两种收口形态，本仓库采用后者：

- 对象收口（局部）：把配件状态打包成一等对象（FAttachmentSet / 组件）；
- **事务收口（采用）**：`UFPSAttachmentService` 唯一写入口 + `OnAttachmentsChanged` 事件 →
  各系统（GAS 授予、视觉、UI、冷却）降级为**订阅者**。

```
新功能 ──→ 订阅 OnAttachmentsChanged（1 处）
写侧    ──→ UFPSAttachmentService（唯一入口，本阶段落地）
读侧    ──→ UFPSAttachmentQuery（设计稿，离体草稿未入库）
```

依赖方向：功能依赖**稳定抽象**（AttachmentID / Data / Service），不依赖**易变内部**（handle / 缓存 / 复制数组）。

## 4. 阶段一落地记录（2026-10-08，实测）

改动清单：

| 文件 | 改动 |
| --- | --- |
| `Source/FPS/Weapon/FPSAttachmentService.h/.cpp`（新增） | 装/卸唯一入口：权威守卫 + 转发（逻辑照搬） |
| `Source/FPS/Weapon/FPSWeaponBase.h` | 新增 `FOnAttachmentsChangedDelegate` / `OnAttachmentsChanged` / `RebuildAttachmentCache()`；接口注释标注唯一入口约定 |
| `Source/FPS/Weapon/FPSWeaponBase.cpp` | 新增 `RebuildAttachmentCache()` 实现；`OnRep` 重建缓存并按槽广播；`BeginPlay` 起始重建；装/卸成功广播 |
| `Source/FPS/Level/FPSWorldWeapon.cpp` | 世界武器预装配件改经服务 |
| `Source/FPS/Weapon/FPSAttachmentTestCommands.cpp` | 验收命令改经服务 |
| `Config/DefaultGame.ini` | 登记 `AttachmentData` 主资产扫描（`/Game/_FPS/Data/Weapon`、`/Game/_FPS/Weapon`） |

行为变化：

- 客户端 `OnRep` 后 `GetAttachment()` / 有效属性恢复可用（修复 RISKS #8 主体）；
- 配件变更现在有**按槽粒度**的事件（服务器端装/卸成功时广播；客户端在 OnRep 时广播）；
- 装/卸入口统一为 `UFPSAttachmentService`（服务器权威；客户端调用会被拒绝并告警）。

验证：`FPSEditor Win64 Development` 编译通过（16 actions，新增/改动文件全绿，零新增 warning）；
`Binaries/Win64/UnrealEditor-FPS.dll` 已更新。

已知边界（本阶段不做）：

- `Content/Script/System/UI/Inventory/WBP_WeaponModify.lua` 仍直接调武器方法（向后兼容，后续迁移到服务）；
- 附件数据资产需放入约定目录才可被扫描解析（未放置时重建会打告警，可在日志观察）；
- 资产按主资产路径**同步加载**（小体量够用，资产多时改异步）；
- 配件 Mesh 展示逻辑仍未实现（RISKS #8 剩余项）；
- 端到端验收（`FPS.AttachmentTest`）的当前前置条件与验收工具问题：见 `RISKS_AND_GAPS.md` #8 尾部（武器数据需配 `SupportedAttachmentSlots`；验收脚本需换 `BP_FPSGameMode` 关卡并等待关卡就绪）。

## 5. 阶段二 / 三（方向级）

- **阶段二：状态归位** —— `FAttachmentRuntimeState`（次数/开关/冷却）挂实例 InstanceID；
  把 `OnEquip` 里的"补授"迁入 `UFPSAttachmentService`，拆掉装备流程与附件系统的耦合。
- **阶段三：物品树化** —— 一切皆物品节点，装/卸=换父级，`InstanceID` 贯通 GA（GA 知道替哪个实例干活）；
  上多人 / 交易时再启动。
- 反向提醒：阶段一已去掉大部分"横穿感"；**收口是对的，重写是贵的**——原型阶段别急着全盘树化。

## 6. 待决问题（2026-10-08 记录，另行跟进）

1. 爆闪手电筒的"使用次数"存在哪？（谁的生命周期最长？谁在复制/存档里活下来？）
2. 策划提"配件可拆下放背包、可交易"时，当前代码要动几处？（变更局部性测试）
3. "配件在不在武器上"现状有几个副本、谁说了算？总账归谁？

## 7. 外部参考摘要（结论级）

- **塔科夫系（SPT / WTT-CommonLib）**：不存在"武器→配件数组"模式，一切皆物品节点由父容器层级回答"装在哪/带在哪"；
  本仓库现有简化版方向没错，差的是"统一账本 + 实例身份贯通"。
- **Lyra（UE 官方样板）**：装备/背包一套系统、GAS 只做能力——官方也不让 GAS 兼做物品账本。
- **Cute of Duty**：规则进表、核心可测——配件功能参数数据化，GA 只留"触发→改状态"薄层。
- 归成三句话：**域界重划**（物品=账本 / GAS=执行 / 表现=订阅）、**单入口事务**、**实例身份**。
