# QuickAbandonFixedForever

`QuickAbandonFixed` 的 WoW Forever 移植版：按住 **Alt** 点击任务，跳过确认框直接放弃。

- 目标分支：`_forever_`，product `wowf`，客户端 `1.60.1.70790`，TOC `## Interface: 16001`，game type `camelot`
- 源插件：`addons/QuickAbandonFixed`（Retail 12.x，TOC `120100`），其本身 fork 自 [sirj0k3r/QuickAbandon](https://github.com/sirj0k3r/QuickAbandon)

## 功能

- 任务日志里 **Alt + 左键** 点击任务标题 → 立即放弃。
- 目标追踪（Objective Tracker）标题 **Alt + 左键** → 立即放弃。
- 不按 Alt 时保持暴雪默认行为；右键行为不变。
- 只对 `C_QuestLog.CanAbandonQuest(questID)` 为真且 `C_QuestLog.IsOnQuest(questID)` 为真的任务生效。
- 发出放弃请求后在聊天框输出一行提示（含任务链接，取不到链接时用任务名）。
- 明确会跳过暴雪确认框，包括「该任务有可放弃物品」的警告。

## 与 Retail 原版的移植差异

| 项目 | Retail 版（`120100`） | Forever 版（本目录） |
| --- | --- | --- |
| TOC | `## Interface: 120100` | `## Interface: 16001` + `## AllowLoadGameType: camelot` |
| 任务日志入口 | 文件作用域直接 `hooksecurefunc("QuestMapLogTitleButton_OnClick", …)` | 运行时解析：优先 `QuestMapLogTitleButton_OnClick`，回退 `QuestLogTitleButton_OnClick` |
| 目标追踪入口 | 直接 hook `ObjectiveTrackerBlockHeaderMixin.OnClick` | 运行时解析：优先 hook `QuestObjectiveTracker`（XML 帧实例）的 `OnBlockHeaderClick`，同时 hook `QuestObjectiveTrackerMixin` 兜底“之后创建的帧”，最后才是 `ObjectiveTrackerBlockHeaderMixin.OnClick` |
| 点击键判定 | 只认 `mouseButton == "LeftButton"` | 同时接受 `"LeftButton"` 与 `"LeftButtonUp"`（见下方“已知坑 1”） |
| 回调参数 | 按位置取 `(block, mouseButton)` | 按形状解析（见下方“已知坑 3”）：`block` = 第一个带数字 `id` 的表，`mouseButton` = 第一个字符串 |
| hook 安装时机 | 文件加载时一次性 | 事件驱动 + 幂等（`ADDON_LOADED` / `PLAYER_LOGIN` / `PLAYER_ENTERING_WORLD` / `QUEST_LOG_UPDATE`），因为该分支的暴雪任务 UI 是按需加载 |
| 提示输出 | `SendSystemMessage` | `DEFAULT_CHAT_FRAME:AddMessage` |
| 任务标识文本 | `GetQuestLink` 必需 | `GetQuestLink` 缺失时回退 `C_QuestLog.GetTitleForQuestID` |
| 诊断 | 无 | `/qaf`、`/quickabandon` 打印已安装的 hook、API 可用性，以及最近一次点击收到的 `mouseButton` / `questID` / 是否发出放弃 |
| 图标资源 | `Resources\QuickAbandonFixed-32.tga` | `Resources\QuickAbandonFixedForever-32.tga`（同一图像，随目录改名） |

核心放弃流程与原版一致，没有改动：`C_QuestLog.SetSelectedQuest(questID)` → `C_QuestLog.SetAbandonQuest()` → `C_QuestLog.AbandonQuest()`。

### 为什么任务日志 hook 要做运行时解析

`Blizzard_UIPanels_Game.toc`（wowf / 70790）按 game type 分发任务日志实现：

```text
[Game]\QuestLogFrame.lua     [AllowLoadGameType vanilla, tbc, wrath]      # 不含 camelot
[Game]\QuestMapFrameOverrides.lua  [AllowLoadGameType camelot]
[Game]\QuestMapFrameUtils.lua      [AllowLoadGameType camelot]
```

`camelot` 加载的是 QuestMapFrame 的两个覆盖文件（`questmapframeoverrides.lua` 注释为 “no tabs in Camelot”），因此 Forever 走 `QuestMapFrame` 路径；同时在 `QuestLogTitleButton_OnClick` 存在时保留经典回退，避免该分支入口名与推断不一致时功能整体失效。

QuestMapFrame 在 `camelot` 上确实在运行，还有一条独立证据：`Blizzard_ObjectiveTracker` 的 quest 追踪代码在左键路径直接调用 `QuestMapFrame_OpenToQuestDetails(questID)`，右键菜单的放弃项调用 `QuestMapQuestOptions_AbandonQuest(questID)`（`blizzard_questobjectivetracker.lua:51-132`）。这两个全局都属于 QuestMapFrame 家族，若它未加载，Forever 的任务追踪点击会直接报错。

### 已知坑：追踪器 header 收到的鼠标键是 `LeftButtonUp`

`blizzard_objectivetrackerblock.lua:382-384`：

```lua
function ObjectiveTrackerBlockHeaderMixin:OnLoad()
	self:RegisterForClicks("LeftButtonUp", "RightButtonUp");
end
```

`RegisterForClicks` 决定 `OnClick(mouseButton)` 收到的是抬起变体，所以 `QuestObjectiveTrackerMixin:OnBlockHeaderClick` 拿到的 `mouseButton` 是 `"LeftButtonUp"` / `"RightButtonUp"`，不是 `"LeftButton"`。

后果：只判断 `mouseButton == "LeftButton"` 的实现在这条链路上永远不会触发 —— Retail 原版 `QuickAbandonFixed` 用的就是这个判断，说明它的追踪器分支在原版客户端上也不生效（任务日志分支正常）。

本版的处理：`IsLeftClick()` 同时接受 `nil`、`"LeftButton"`、`"LeftButtonUp"`，右键（`"RightButton"` / `"RightButtonUp"`）一律放过；并且每次点击都把 `mouseButton` / `questID` / 是否发出放弃记进 `/qaf` 的 `last ... click` 两行，避免再靠猜。

### 已知坑 2（1.0.2 修复）：要 hook 的是 `QuestObjectiveTracker` 帧，不是它的 mixin

`blizzard_questobjectivetracker.xml:26`：

```xml
<Frame name="QuestObjectiveTracker" mixin="QuestObjectiveTrackerMixin" inherits="ObjectiveTrackerModuleTemplate"/>
```

`mixin=` 由 XML 的 `Mixin()` 在**帧创建时**把 mixin 的方法拷到帧自己的字段上。所以：

- 帧已经存在之后再改 `QuestObjectiveTrackerMixin.OnBlockHeaderClick`，对那个帧毫无作用 —— 帧查的是自己的 `OnBlockHeaderClick` 拷贝；
- 证据：`Blizzard_ObjectiveTracker.toc` 的顺序是 `Blizzard_QuestObjectiveTracker.lua`(35) → `[Game]/Blizzard_QuestObjectiveTrackerOverride.lua`(36) → `Blizzard_QuestObjectiveTracker.xml`(37)。暴雪自己的 camelot 覆盖文件必须在 XML 之前执行，否则 `QuestObjectiveTrackerMixin:CanShowTimerBar` 这类覆盖同样不会生效。

1.0.1 挂的是 mixin，`/qaf` 报“已安装”但点击永远进不来 —— 这就是追踪栏不生效的原因；任务日志侧挂的是**全局函数** `QuestMapLogTitleButton_OnClick`（XML 用函数名解析，替换全局即生效），所以一直正常。

1.0.2 起：

- 优先 `hooksecurefunc(QuestObjectiveTracker, "OnBlockHeaderClick", …)`（帧实例，必然命中）；
- 仍然 hook mixin，作为“之后才创建的帧”的兜底；
- 两条路径可能看到同一次点击，用 0.15 秒 / 同 `questID` 的去重窗口折叠，`/qaf` 显示 `(live module frame)`、`(for frames created later)`、`(fallback)` 三个来源。

结论：这不是暴雪限制。放弃任务本身只是 `C_QuestLog` 的三个普通调用，而且任务日志侧在同一客户端上已经证明可行；追踪栏失败纯粹是 hook 目标选错（mixin 表 vs 帧实例）。

### 已知坑 3（1.0.3 修复）：`hooksecurefunc(表, "方法", fn)` 会把 `self` 一起转给回调

1.0.2 游戏内实测 `/qaf` 打出：

```text
last tracker click: table: 0000026AB66BEE00 id=nil sent=false
```

即回调的第一个参数是**帧**、第二个参数是**块**、`mouseButton` 被挤到第三位。原因：`QuestObjectiveTracker:OnBlockHeaderClick(block, mouseButton)` 是冒号调用，实参是 `(self, block, mouseButton)`；`hooksecurefunc` 的对象形式把原调用参数**原样**转给回调，不像字符串形式那样只给 XML 绑定的参数。1.0.2 按 `(block, mouseButton)` 读，于是 `block` 拿到帧（没有 `id`）、`mouseButton` 拿到块（`tostring` 成 `table: …`）。

1.0.3 改为按形状解析而不依赖位置：

- `block` = 第一个带数字 `id` 的表参数；
- `mouseButton` = 第一个字符串参数；
- 兜底：若没找到带 `id` 的表，取第二个表参数。

`/qaf` 的 `last tracker click` 现在还会带上 `argc=… types=…`，把实际参数形状固化下来，便于下次一眼判断。

## Forever 侧 API 依据（CASC `wowf` / build `70790`）

| 依据 | 内容 |
| --- | --- |
| `blizzard_apidocumentationgenerated/questlogdocumentation.lua` | `C_QuestLog.SetSelectedQuest`、`SetAbandonQuest`、`AbandonQuest`、`CanAbandonQuest`、`IsOnQuest`、`GetTitleForQuestID`、`GetQuestIDForLogIndex` 均存在，签名与 Retail 一致 |
| `blizzard_objectivetracker/blizzard_objectivetrackerblock.xml` | `HeaderButton` 的 mixin 为 `ObjectiveTrackerBlockHeaderMixin`，header 父级即 block |
| `blizzard_objectivetracker/blizzard_objectivetrackerblock.lua:284-286、380-399` | `ObjectiveTrackerBlockHeaderMixin:OnClick(mouseButton)` → `block:OnHeaderClick(mouseButton)` → `self.parentModule:OnBlockHeaderClick(self, mouseButton)` |
| `blizzard_objectivetracker/blizzard_questobjectivetracker.lua:20、51-132` | `QuestObjectiveTrackerMixin` 由 `CreateFromMixins` 生成；`OnBlockHeaderClick(block, mouseButton)` 左键打开任务详情、右键弹菜单（含放弃） |
| `blizzard_objectivetracker/blizzard_objectivetrackermodule.lua:254-272` | `GetBlock(id)` 中 `block.id = id`，任务是 `questID` |

证据取自客户端 CASC 的 `interface/addons/…` 段（`wowf` build 70790）：`Blizzard_ObjectiveTracker`、`Blizzard_UIPanels_Game.toc`、`blizzard_apidocumentationgenerated/questlogdocumentation.lua`。

## 验证状态

已完成（静态）：

- `lua5.1 -e "loadfile(...)"` → `SYNTAX OK`
- 假客户端环境夹具（本地脚本，不随仓库发布）→ `FIXTURE OK`，两轮独立客户端覆盖：
  1. 轮 A（只有 header mixin）：任务 UI 未加载时安装器不抛错、`/qaf` 报 `not installed`；`QuestMapLogTitleButton_OnClick` 出现后 Alt+左键放一次；未按 Alt 不放；不可放弃任务不放；header 的 `LeftButton` / `LeftButtonUp` 都放、`RightButton` 不放。
  2. 轮 B（模块帧可用）：帧 + mixin 都 hook、header 兜底不安装；帧的 `LeftButtonUp` / `LeftButton` 都放、`RightButtonUp` 不放、不可放弃块不放；同一次点击同时被帧和 mixin 看到时只放一次（去重窗口）；`last tracker click` 诊断行内容正确；重复事件触发不重复挂 hook（幂等）。

已完成（游戏内）：

- 客户端 `_forever_` 1.60.1.70790，TOC 16001 正常加载，`/qaf` 显示 hook 与 API 齐全。
- **任务日志 Alt+左键放弃：可用**（1.0.0 起）。
- 目标追踪的修复过程（每一步都有游戏内反馈支撑）：
  - 1.0.0：`mouseButton` 实际是 `"LeftButtonUp"`，判断 `"LeftButton"` 不匹配；
  - 1.0.1：键值放开后仍不触发，因为 hook 挂在 mixin 表而不是 `QuestObjectiveTracker` 帧；
  - 1.0.2：改挂帧后 hook 命中，但 `/qaf` 显示 `id=nil`、`mouseButton` 是 `table` —— `hooksecurefunc` 把 `self` 也转给了回调，参数整体右移一位；
  - 1.0.3：按形状解析参数，**等待 `/reload` 复验**。

未完成（需游戏内）：

- 1.0.3 的追踪器修复尚未在客户端复验。
- `QuestMapLogTitleButton_OnClick` 使用 `self.questID` 的字段契约无法从 CASC 直接核对（游戏内已证明可用）。2026-11-05 复测：`interface/framexml/*` 的 750 条 listfile 候选在 `wowf` **与** `wow` 上 `--verify` 全部失败（`questmapframe.lua`、`questlogframe.lua`、`uiparent.lua` 皆不可读），因此这属于客户端数据下发范围的共性，不是 Forever 分支差异；可读的是 `interface/addons/*` 段，上述依据都来自该段。
- `[Game]` 段对应 `camelot` 目录属间接推断（依据：`camelot/blizzard_questobjectivetrackeroverride.lua` 存在，且 `Blizzard_ObjectiveTracker.toc:36` 用 `[AllowLoadGameType camelot]` 加载它）。

游戏内确认方法：`/reload` 后执行 `/qaf`，应看到

```text
quest log hook: QuestMapFrame (QuestMapLogTitleButton_OnClick)
objective tracker hook: QuestObjectiveTracker (live module frame) + QuestObjectiveTrackerMixin (for frames created later)
api: C_QuestLog, IsAltKeyDown, GetQuestLink
last tracker click: LeftButtonUp id=<任务ID> sent=true argc=3 types=table,table,string
```

第四行在 Alt+左键点过目标追踪标题后应出现，`sent=true` 表示放弃请求已发出；`argc`/`types` 是实际回调形状的快照。

若仍不生效，看 `last tracker click` 行：`none yet` 说明点击没进这个 hook（入口不同），`sent=false` 说明键位或任务状态被拦，把整段输出反馈即可继续定位。

## 安装

将 `QuickAbandonFixedForever` 目录放入 `_forever_\Interface\AddOns\`，然后 `/reload`。目录需包含 `QuickAbandonFixedForever.toc`、`QuickAbandonFixedForever.lua` 和 `Resources` 文件夹。

## 回滚

删除 `_forever_\Interface\AddOns\QuickAbandonFixedForever`（或移除对应 Junction）即可；插件无 SavedVariables、无外部库、不改动全局默认行为。

## 许可

MIT License，见 [LICENSE](LICENSE)。原始代码版权归 sirj0k3r。
