# ocr2md-syncbar

`ocr2md-syncbar` 是 ocr2md 的本地优先（local-first）同步基础设施：用 **Unison** 在多个本地/云盘挂载目录之间同步文件，并由原生 macOS 菜单栏 App 提供状态、目录组管理和冲突入口。

> 本项目的核心原则：**文件库是事实源，应用和云服务都是可替换的加工/传输层。**

最后更新：2026-09-01

---

## 1. 当前架构

```text
                    ┌────────────────────┐
                    │ OCR2MD Sync Status │
                    │  macOS native App  │
                    └─────────┬──────────┘
                              │ read/write config & state
                              ▼
                  sync-groups.json
                              │
                              ▼
                    group-sync.py
                              │
                generate Unison profiles
                              │
                              ▼
                          Unison
                  ┌───────────┼───────────┐
                  ▼           ▼           ▼
              Directory A Directory B Directory C ...
```

同步执行由 LaunchAgent 周期性启动：

```text
~/Library/LaunchAgents/com.ocr2md.unison-sync.plist
        ↓
~/Library/Application Support/ocr2md-sync/unison-sync.sh
        ↓
~/Library/Application Support/ocr2md-sync/group-sync.py
        ↓
Unison generated profiles
```

菜单栏 App **显示和管理同步**，真正的数据同步由 runner + Unison 完成。

---

## 2. 核心概念

### 2.1 同步目录组

用户管理的是目录组，而不是 Unison 的 pair：

```text
目录组 A
├── 目录 1
├── 目录 2
├── 目录 3
└── ...
```

底层由 runner 自动展开为必要的 Unison 连接。

普通双向目录采用 hub-and-spoke；当目录级排除需要保持正确语义时，runner 会自动补充必要的 spoke-to-spoke 边。

### 2.2 同步类型

当前支持：

- `mirror`：工作副本，和其他工作副本双向收敛。
- `version_backup`：版本备份，只接收工作副本更新，不允许备份目录的改动反向传播。

UI 中普通镜像目录显示：

- `镜像`：无自定义排除。
- `有排除`：该目录存在自定义排除项。

### 2.3 目录级排除

排除属于**单个目录**，不是整个目录组的全局规则。

例如某个云盘目录排除：

```text
.obsidian
.obsidian-ipad
.obsidian-iphone
.obsidian-mac
config-sync
```

则这些路径不进入该目录，但仍可在其他未排除它们的工作副本之间同步。

### 2.4 引擎级排除

以下内容不是用户文档，不参与镜像一致性判断：

```text
.DS_Store
.sync.ffs_db
._*
.unison.*.unison.tmp
```

“文件数”统计同样忽略这些引擎/系统元数据，并应用目录自己的排除规则。

---

## 3. 运行时文件

本机运行时文件不放入 Git：

```text
~/Library/Application Support/ocr2md-sync/
├── sync-groups.json
├── group-sync.py
├── unison-sync.sh
├── unison-state.txt
├── unison-conflicts.json        # 有冲突时
├── full-scan-state.json         # Google Drive 定期安全扫描时间戳
├── unison-backups/
└── ...
```

Unison 配置：

```text
~/Library/Application Support/Unison/
├── ocr2md.prf                   # 保留的 legacy profile / rollback reference
└── ocr2md-group-*.prf           # runner 自动生成，禁止手工编辑
```

日志：

```text
~/Library/Logs/ocr2md-sync/unison.log
~/Library/Logs/ocr2md-sync/unison-run.log
```

原生 App：

```text
~/Applications/OCR2MD Sync Status.app
```

> README、示例配置和 Git 提交中不要写入个人云盘账号、OAuth token、Apple ID、完整私人路径或其他凭据。

---

## 4. 安全不变量

修改同步逻辑时必须保持以下约束：

1. **Unison 以普通用户身份运行，不使用 root。**
2. `links = false`，不同步符号链接目标。
3. `perms = 0`、`owner = false`、`group = false`、`xattrs = false`、`times = false`，避免不同 File Provider 的元数据差异污染文档身份。
4. `confirmbigdel = true`，保留大规模删除保护。
5. `copyonconflict = false`，发生冲突时不自动选择胜者。
6. 冲突原则是 **freeze first**：先停止传播，再人工裁决；禁止“为了继续同步”而自动覆盖任意一边。
7. 备份保存在同步目录之外的 central backup 中。
8. 新的目录组配置必须先 `--validate-only`，验证生成 profile 后才能投入自动运行。
9. 改 runner / profile / config 前先做本地备份，并确认当前 lock 为空。
10. 不因为调试方便而默认授予 Full Disk Access；只有明确遇到 TCC 权限问题才考虑增加权限。

---

## 5. 技术决策记录

这是本 README 最重要的部分。**已淘汰方案不能仅因“看起来功能很多 / Star 很高”就重新进入候选。**

重新考虑一个已淘汰方案之前，必须先回答：

> 原来失败的具体问题是什么？新版是否明确修复？能否用同一测试重新证明？

### TD-001：生产同步引擎选择 Unison

**状态：Accepted**

原因：

- 开源。
- CLI 原生，适合后台自动测试和自动化。
- 双向同步模型清楚。
- 冲突行为可控。
- 已在 ocr2md 的真实 iCloud / Google Drive / OneDrive File Provider 环境中通过新增、修改、删除、反向传播和多目录收敛测试。

代价：

- Unison 单次只理解两个 root。
- N 路目录组必须由 `group-sync.py` 编排。

结论：**继续把 Unison 当同步内核；我们只维护薄的目录组编排层，不重写文件同步算法。**

### TD-002：rclone / rclone bisync 已淘汰

**状态：Rejected / Retired**

历史测试中，rclone bisync 被认为风险过高：

- 官方本身将 bisync 定位为 advanced command，并强调错误使用存在数据丢失风险。
- 本项目实际测试曾暴露不安全的删除行为，随后才转向 Unison。
- rclone 的 pair 模型也不能直接解决本项目的 N 路目录组语义。

因此：

**不要因为 rclone 开源、Star 高、云 API 多，就直接重新推荐或重新引入。**

只有在能够还原原失败测试，并证明某个新版已经解决该失败点后，才允许重新评估。

仓库中残留的 rclone 脚本属于历史参考，不是生产路径。

### TD-003：Rclone UI 已淘汰

**状态：Rejected / Retired**

原因：GUI-first，不符合本项目“尽量通过 CLI 让自动化代理自行检查、测试和操作”的工作方式；多目录编排仍然需要额外逻辑。

### TD-004：FreeFileSync / RealTimeSync 已淘汰

**状态：Rejected / Retired**

早期试验后弃用。核心问题之一是工作流不够 CLI-native，不适合作为可以被自动化代理完整控制和测试的同步基础设施。

若未来有人希望重新引入，必须先补齐原始失败复现和对比测试，不能仅依据 GUI 功能表决定。

### TD-005：SwiftBar 已淘汰，改用原生 AppKit 菜单栏 App

**状态：Accepted replacement**

SwiftBar 适合快速原型，但目录组管理、状态动画、菜单生命周期、冲突管理等需求增长后，需要对 UI 状态和行为有更直接的控制，因此改为原生 macOS App。

当前生产 UI 位于：

```text
native/
```

仓库中的：

```text
swiftbar/
```

属于历史实现。

### TD-006：排除必须是目录级，而不是隐藏在 legacy profile 中

**状态：Accepted**

曾经 `.obsidian*` / `config-sync` 被写在旧 `ocr2md.prf` 中，导致所有边一起继承排除，UI 显示与实际行为不一致。

现在规定：

- 云盘/目录的业务排除写入 `sync-groups.json` 对应 directory。
- legacy profile 中的业务 `ignore` 不再作为全组规则继承。
- 只有引擎/OS 元数据排除可以是全局规则。

### TD-007：云服务文件名限制在源头处理

**状态：Accepted**

OneDrive 和 macOS/iCloud 对合法文件名的规则不同。

已遇到的 OneDrive 不兼容类型包括：

- `?` 等 OneDrive 禁止字符。
- 文件名前导空格。
- 文件/目录名末尾空格或 `.`。

处理原则：

1. 不让 OneDrive 客户端自行批量重命名后再双向传播。
2. 先暂停同步。
3. 在工作源目录统一改成跨平台合法名称。
4. 恢复同步，让改名正常传播。
5. 再比较相对路径集合，而不是只看文件数量。

### TD-008：文件数只是诊断指标，路径集合才是镜像证明

**状态：Accepted**

两个目录“文件数相同”不代表真正镜像。

验证镜像必须至少比较：

```text
relative-path set A == relative-path set B
```

必要时再比较内容 hash。

目录有排除时，应比较：

```text
A 应用目标目录排除后的集合 == B
```

### TD-009：文件库优先于云服务

**状态：Accepted**

Google Drive、OneDrive、iCloud 都是同步/版本/访问基础设施，不是唯一事实源。

核心资产应保持为普通文件（Markdown、JSON、图片、PDF 等）。替换某个云服务或某个应用，不应导致数据失去可读性。

### TD-010：Google Drive File Provider 使用周期性完整“发现扫描”补足 fastcheck

**状态：Accepted**

2026-09-01 的真实测试发现：Web 通过 Google Drive API 新建 Markdown 后，Google Drive Desktop 已把文件物化到本地，但父目录 `mtime` 没有随之更新。Unison 默认 `fastcheck` 因此连续报告 `Nothing to do`，漏掉了实际存在的新文件；同一条 edge 使用 `-fastcheck false` 后立即识别为 `new file` 并正确传播。

不能把 `fastcheck=false` 永久用于每个 10 秒轮询周期：生产 vault 的完整扫描实测约 9–13 秒，会造成持续高负载。也不能在 LaunchAgent 中自行遍历云盘做路径指纹：Python 和系统 `find` 都被 macOS TCC 以 `Operation not permitted` 阻止，而本项目不为这个优化默认要求 Full Disk Access。

因此采用以下混合策略：

1. 常规 10 秒轮询继续使用 Unison 默认 `fastcheck`，保证已有文件修改快速传播。
2. 每个 Google Drive File Provider mount 只指定一条 **discovery edge**。
3. discovery edge 每 60 秒至少执行一次 `-fastcheck false`，主动发现因目录 `mtime` 异常而被 fastcheck 漏掉的新增/删除路径。
4. 优先把双向 mirror edge 作为 discovery edge；如果 Google Drive 只有单向输出到版本备份，则该单向源 edge 承担 discovery 职责。
5. 同一个 Google Drive provider 的其他 edge 不做无条件周期完整扫描；但是**第一 sweep 的任意 edge 一旦实际报告 `new file` / `new dir` / `deleted`，立即停止这一 sweep 的后续 edge，并把第二 sweep 整体升级为 `-fastcheck false`**。这样后续 edge 不会拿“部分已经发现、部分还没发现”的路径视图做决策，尤其防止多个 `force = source` 版本备份 edge 在备份端发生复制/删除抖动。
6. 路径拓扑变化属于低频事件，因此完整 convergence sweep 只在真的发现新增/删除时发生；普通内容修改不会触发。
7. 只有 discovery edge 的完整扫描成功后才更新 `full-scan-state.json`；失败或冲突不算完成安全扫描。
8. `unison-sync.sh` 的单实例锁保持不变：完整扫描超过 10 秒时，后续 LaunchAgent 触发会直接退出，不允许两个 Unison 实例重叠。

当前生产拓扑中只有 `iCloud ↔ Google Drive` 做无变化时的周期 discovery full scan；Google Drive → OneDrive 平时仍走 fastcheck，但一旦本轮发现路径拓扑变化，会随整组收敛自动升级 full scan。

这是一层 **发现可靠性补丁**，不是重新实现同步算法：内容比较、冲突识别和传播仍全部交给 Unison。

---

## 6. 冲突原则

冲突不是“错误后继续跑”，而是一个需要用户裁决的状态。

期望流程：

```text
检测到同一文件双方同时修改
        ↓
停止该冲突的继续传播
        ↓
保存双方原版本
        ↓
显示双方版本 / 差异
        ↓
用户选择保留哪一边
        ↓
重新运行 Unison
```

禁止默认使用“最近修改时间”“云盘优先”“iCloud 优先”等规则自动覆盖真正的双边冲突。

---

## 7. 修改同步系统前的检查清单

任何涉及 runner / Unison / 目录组的修改，先做：

```sh
git status -sb

cat "$HOME/Library/Application Support/ocr2md-sync/unison-state.txt"

"$HOME/Library/Application Support/ocr2md-sync/group-sync.py" --validate-only

launchctl print "gui/$(id -u)/com.ocr2md.unison-sync"
```

推荐顺序：

1. 只读检查当前 runner、config、profile、state。
2. 确认同步当前空闲。
3. 备份将修改的运行时文件。
4. 在隔离临时目录中测试新语义。
5. `--validate-only`。
6. 才替换正式 helper / runner。
7. 用一个无害临时文件做新增、反向传播、删除验证。
8. 清理测试文件。
9. 检查日志、状态和所有目录的相对路径集合。
10. 最后才提交 Git。

---

## 8. 当前仓库中需要警惕的历史遗留

以下内容来自早期 rclone / SwiftBar 阶段，**不要自动认为仍是生产组件**：

```text
swiftbar/
scripts/parse-rclone-status.sh
scripts/doctor.sh
config/local.env
config/config.example
install.sh
```

特别是根目录的 `install.sh` 和旧 `doctor.sh` 仍按 SwiftBar/rclone 架构编写。在完成现代化之前，**不要用它们部署当前 Unison 原生 App 架构**。

后续应将这些历史文件移入 `legacy/` 或删除，并重写当前版本的 installer / doctor。

---

## 9. 维护原则

- 优先采用成熟、开源、CLI-native 的基础工具。
- 自己的代码只解决项目独有的编排和 UI，不重新实现成熟同步算法。
- 每次踩坑都应补一条技术决策或 incident note。
- “已经试过但失败”的信息与“当前成功方案”同样重要。
- README 中的技术决策优先级高于临时聊天结论；改变已接受决策时，应同步修改 README 并说明原因。
