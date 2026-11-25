# 流影 (LiuYing)

iPhone 快捷指令 → iCloud Drive → Mac 常驻 → 自动下载 B 站视频。
是旧版 Python `bili-watcher` 的 Swift 重写，多了一个菜单栏界面、图形化设置和视频库。

- 编码优先级 **av1 > hevc > avc**，画质按大会员权限取可得最高档
- 下载后按编码自动 remux：av1 → mkv、hevc → mov、avc → mp4；无损音轨装不进 mp4/mov 时退回 mkv
- 只有 bili-dl 确实产出文件、且链接来自 links.txt 时才删掉对应行（其余行逐字节保留）；Downie 是异步入队，不删行，避免「没下成但链接没了」
- **跨设备去重**：已入队链接的去重键写进 links.txt 同目录的 `liuying-known-keys.txt`，随 iCloud 同步；新机启动先导入清单再采集 links.txt，因此换机不会把旧视频全部重下一遍（详见下方「跨设备去重同步」）
- 失败按指数退避重试（普通 30s 起、412 风控 300s 起），不会在同一轮里连打 3 次
- 交给 Downie 的任务进「已交给 Downie」状态，确认下载完成后手动标记，期间不删 links.txt
- 除 iCloud 链接文件外，还支持手动粘贴、剪贴板监听、UP 主订阅追更

## 后端路由

不是「二选一」，也不是「失败后回退」，而是**按链接域名选择后端**：

| 链接 | 后端 | 默认 |
| --- | --- | --- |
| `b23.tv` / `bilibili.com` / `bilibili.tv` | bili-dl（内嵌） | bili-dl（内嵌） |
| 其它一切 http(s) 链接 | Downie | Downie |

两个方向都能在「设置 → Downie → 路由」里改。后端在**任务开始下载那一刻**按当前设置选定，排队中的任务改设置后会跟着换。
想看某个链接会怎么走：`liuyingctl route <url>`（只打印命令，不下载）。

> 注意：抓取面现在是**所有 http(s) 链接**。所以 links.txt 或剪贴板里混进任何网址，
> 都会被交给 Downie。剪贴板监听默认关闭，就是这个原因。

---

## 构建与安装

```bash
swift build && swift test          # 238 个单测
./build-app.sh                     # 产出 .build/release/流影.app（含内嵌 bili-dl）
```

`build-app.sh` 会先编译 Swift，再从 `BILI_DL_SRC`（默认 `/Users/yufei/Git/bili-dl`）
用 Go 编译 bili-dl，拷进 `.app/Contents/MacOS/` 并一起签名。源码在别处时用环境变量指定：

```bash
BILI_DL_SRC=/path/to/bili-dl ./build-app.sh
```

安装（`/Applications` 对 admin 组可写，**不需要 sudo**）：

```bash
pkill -f "/Applications/流影.app/Contents/MacOS/liuying"
rm -rf "/Applications/流影.app"
ditto "/Users/yufei/Git/liuying/.build/release/流影.app" "/Applications/流影.app"
open "/Applications/流影.app"
```

用 `ditto` 而不是 `cp -R`：它保留权限与扩展属性，是拷 app bundle 的标准做法。
**bundle 文件名必须保持 `流影.app`** —— TCC 授权按路径登记，换个名字就等于换了个 App，得重新授权。

`.app` 用 `Apple Development: yufei.im@gmail.com` 签名（脚本会自动选）。
**这一点很重要**：TCC 授权绑定代码签名，ad-hoc 签名每次重编都会变、授权就失效；
固定身份签名能让授权跨重编保留。

---

## 首次运行必须做的两件事

### 1. 授予文件访问权限

流影要读两个受 macOS 保护的位置：iCloud 里的 `links.txt`，以及下载目录 `~/Downloads/Bilibili`。
首次访问时系统可能弹窗询问；如果没弹（比如屏幕锁定、或用 `open` 后台启动），请求会在
syscall 层挂住，App 会在 30 秒后放弃并显示「访问被系统挂起」。

最省事的做法：**系统设置 → 隐私与安全性 → 完全磁盘访问权限**，把 `/Applications/流影.app` 加进去。
App 内「设置 → 通用 → iCloud 访问 → 打开系统设置」有直达按钮。

授权后重启 App。设置页的「iCloud 访问」应显示「可访问」。

> 如果 iCloud 实在授权不了，可以退一步：把 iPhone 快捷指令写的文件放到 iCloud 之外
> （例如 `~/Documents/Bili/links.txt`），在「设置 → 监听文件」里手动指定它。

### 2. 旧版 Python 服务已停用

旧版 `com.felix2yu.bili-watcher` 的 LaunchAgent 已被停用：
进程已终止，plist 移到了
`~/Library/Application Support/LiuYing/backups/launchagents/`，并且写进了 launchd 的 disabled 数据库。

需要恢复时：`liuyingctl legacy restore`（或设置页「恢复旧服务」）。

---

## 界面

菜单栏图标常驻，关掉窗口也继续轮询。

主窗口采用侧边栏布局：视频库 / 队列 / 订阅固定在左侧，底部常驻引擎状态与暂停按钮；内容区只保留大标题、筛选条与行卡片。列表字号、行高和按钮尺寸按 4K 视网膜屏的可读性统一放大，长说明收进「ⓘ」提示，不再铺满小字。工具栏右侧是搜索、添加链接与设置。

- **视频库**：扫下载目录，按 UP 主分组筛选；大缩略图卡片，点一行就地展开详情，可播放（mkv/AV1 可用 IINA）、访达中显示、复制路径、删除。
- **队列**：待处理 / 下载中 / 已完成 / 失败 / 已取消 / 已交给 Downie；展开当前任务能看实时 bili-dl 日志。取消是终态，需要时在队列里点「重新下载」；退避中的任务会显示下次重试时间。默认显示最近 30 条，底部「加载更多历史」可逐次翻到更早的记录。手动添加后会显示新增／去重明细，并提供「撤销本次添加」（已开跑的不撤销）。
- **订阅**：填 UP 主 UID 自动追更。**首次同步只记录水位，不下载历史投稿**；要补看用「导入最近 5 条」。连续 3 次失败会自动停用（风控熔断）。
- **设置**：主窗口工具栏齿轮或菜单栏「设置…」都能打开；四个 tab 分别管路径与轮询、bili-dl 参数、Downie、以及高级项（SESSDATA、旧服务、一次性清理链接文件、日志目录、恢复默认设置）。通用页会显示下载目录实际解析结果、通知授权状态。
- **菜单栏**：展开菜单能看到启动失败、引擎未运行、上一轮检查时间与清理错误；引擎未就绪时相关命令置灰，不会点了没反应。点「✓ 最近完成」会按任务产出文件路径跳到视频库对应条目。「导入 Downie 下载记录…」在这里，与主窗口工具栏的「+」各自独立。
- **快捷键**：主窗口聚焦时按 ⌘V，直接把剪贴板里的链接加入下载队列；在输入框里按 ⌘V 仍是普通粘贴。开关在「设置 → 通用 → 行为」。

---

## 命令行

```bash
liuyingctl doctor                    # 环境自检（依赖解析、SQLite）
liuyingctl status                    # 任务库统计 + 最近记录
liuyingctl config show               # 当前配置
liuyingctl config set watch_file ""   # 改配置（重启 App 生效）
liuyingctl test <url> [额外 bili-dl 参数…]   # 直接下一单，绕过采集与去重
liuyingctl legacy status|retire|restore
liuyingctl bili smoke <BV>           # 实网检查：nav / view / arc-search
liuyingctl bili sign <mid>           # 打印 arc/search 的签名中间量
```

路径：`<app>/Contents/MacOS/liuyingctl`。

> iCloud 读写**只能在 .app 里**做。直接跑裸二进制时 TCC 归属终端，会 EPERM ——
> 这不是 bug，是 TCC 的责任进程规则。

---

## 跨设备去重同步

换到新 Mac 时 `state.db` 是空的，而 iCloud 的 links.txt 里可能还残留着大量已下载过的链接行
（例如下载被中断没删成行、或 Downie 任务）。空库采集时这些旧行会被全部当成新链接下载。
解决办法是把「去重记忆」也跟着 iCloud 走：

- 每个成功入队的链接，其去重键会被写进 **links.txt 同目录**的 `liuying-known-keys.txt`
  （纯文本，每行一个键）。文件和 links.txt 在同一个 iCloud 容器里，自动同步到新机。
- 新机启动后、**采集 links.txt 并去重入队之前**，先把清单里的键导进本地库（存在独立的
  `known_keys` 表，不建任务、不进队列），之后 `knownKeys()` 会把这些键和任务表的键一起算进去。
  于是旧行被挡住，只有新加的那一条会下载。
- 两台 Mac 同时写时取**并集**：写入前先读现有清单合并，绝不删掉文件里已有的键，因此不会
  互相覆盖。读写都带死线，iCloud 占位符/TCC 待授权时不会卡住引擎。
- 清单只含去重键，不含视频文件，也不含产出路径；视频库始终按磁盘扫描建立。

开关在「设置 → 高级 → 跨设备去重同步」，默认开启。该区还能看到清单真实路径、已导入键数，
并可手动「从清单导入」/「导出到清单」（例如某台机器错过同步后补一次）。

> 为什么不直接同步 `state.db`：SQLite 的 WAL/-shm 与 iCloud 的逐文件同步、冲突副本机制不兼容，
> 多机同写极易损坏数据库。清单是只增、可并集合并的纯文本，天然抗冲突。

## 数据位置

| 内容 | 路径 |
| --- | --- |
| 状态库 | `~/Library/Application Support/LiuYing/state.db` |
| 日志 | `~/Library/Logs/LiuYing/liuying.log`（1MB 轮转） |
| 缩略图缓存 | `~/Library/Application Support/LiuYing/thumbs/` |
| 备份 | `~/Library/Application Support/LiuYing/backups/` |
| 临时工作目录 | `~/Library/Application Support/LiuYing/work/task-<id>` |
| 配置 | `~/Library/Preferences/im.yufei.liuying.plist` |
| 去重键清单（随 iCloud 同步） | 与监听的 links.txt 同目录，文件名 `liuying-known-keys.txt` |

---

## Downie 下载记录导入

Downie 没有公开的「读取历史记录」接口：它的历史库在沙盒容器
`~/Library/Containers/com.charliemonroe.Downie-4/…` 里，受 TCC 保护、格式未文档化，
还会经 CloudKit 同步。直接读它既需要完全磁盘访问权限，也会随 Downie 版本失效。
因此本应用**只读用户自己导出的文件**：

在 Downie 里 `窗口 → 显示历史记录`，用工具栏的导出动作保存 `Downie History Export.xml`
（不要勾「包含预览图」，文件会小很多）。然后在菜单栏选「导入 Downie 下载记录…」，
通过打开面板选中文件 —— 系统会为这个文件单独授权，不需要额外的磁盘权限。

| 支持的输入 | 取什么 |
| --- | --- |
| Downie 历史导出 XML | `url` / `originalWebSiteURLString` 等字段里的原始页面链接 |
| 官方导入格式 XML | `<downloads><download><url><title><path>` |
| XML plist / Downie CSV | plist 的 `url` 键、`url,title[,path]` 列 |
| 纯链接清单 TXT | 正文或每行里的 http(s) 链接 |

**可导入的数据范围**：只有原始页面 URL（必需）与标题（可选）。导入后登记为
「已完成」记录（来源「Downie 导入」、后端 downie、状态 done、attempts=0），
不触发下载、不删 links.txt、不写产出文件——导出文件里的本地路径不能证明本机确有这个文件，
视频库仍按磁盘扫描建立索引。画质／字幕／后处理／登录态／预览图／失败或排队中的条目／
下载队列状态都不导入。

导入明细把三类结果分开报：**文件内重复**（同一个 URL，或归一后同一个 BV 键）、
**对应下载任务已存在**（任务库里本来就有该去重键，不论原任务是什么状态）、**新增**。
已有任务不会被改写；导入后可「撤销本次导入」，只删本次新增的归档记录。
需要重新下载时，在队列里对这条点「重新下载」，走既有的 requeue 流程。

不认的输入会明确报错而不是静默导入：空文件、二进制、超 32 MB、JSON、无关 XML 根元素、
XML 语法错误、文件里没有 http(s) 链接。

## 主窗口 ⌘V 直接下载

与 Downie 自身的交互一致（官方帮助：主窗口活动时按 ⌘V 加载剪贴板里的链接），默认开启，
可在「设置 → 通用 → 行为」整体关掉。全部满足下列条件才消费按键：

1. 应用处于激活状态，且焦点窗口是主窗口（不是设置窗口、菜单栏面板）；
2. 主窗口没有 sheet / modal；
3. 第一响应者不是可编辑文本控件（搜索框、添加链接输入框、订阅输入、设置页输入框等）；
4. 按键是纯 ⌘V —— ⌘⇧V / ⌘⌥V / ⌃⌘V 一律放行；
5. 剪贴板里至少有一个 http(s) 链接。

命中后走既有 `addManual` 流程：B 站四个主机走 bili-dl，其它 http(s) 链接按当前路由走 Downie；
b23.tv 短链、分享文案里夹着的链接都认；⌘V 只负责入队，仍由引擎串行下载。
底部会显示一条自动消失的提示，带「撤销」按钮（已开跑的不撤销）。

剪贴板为空、只有纯文本／图片／文件、格式不匹配时**不拦截**，事件原样交回系统，
只给一条轻提示；输入框里的 ⌘V 完全是普通粘贴。
重复链接和「对应任务已存在」由既有去重键处理，提示里会显示跳过数。

实现上用 local event monitor 而不是替换系统 Paste 菜单项 —— 后者会把 `paste:` 从
第一响应者手里抢走，输入框就粘不进东西了。

---

## 已知限制

- **remux 之后 bili-dl 认不出已有文件**：我们把 bili-dl 产出的 `.mp4` remux 成 `.mkv`，
  下次同一个视频再入队时 bili-dl 看不到预期的 mp4，会重新下载一遍。
  正常的去重靠状态库的 BV 键，所以只有「手动 test」或换库后才会遇到。
- **多 P 命名**：bili-dl 沿用的规则是 P1 无后缀、P2 起 `标题 (1).mkv`。库里会把后缀解析成页码，但页码从 1 开始对应 P2。
- **订阅追更依赖 SESSDATA**：`arc/search` 匿名访问会被 412 风控。程序从 bili-dl 共用的
  `~/.config/yutto/auth.toml` 读 `[profiles.default].sessdata`，并在被 ban 时换新签名重试最多 3 次。
- **Downie 不会自己开始下载**：`downie://` 只支持 `url` / `postprocessing` / `destination` /
  `action` / `title` 五个参数（Downie 自带帮助的 Automation 一节），**没有「立刻开始」这种参数**。
  必须先在 Downie 里打开 **设置 → 高级 → 自动化模式**，它才会抑制质量/字幕对话框直接下载。
  这个开关的作用是「抑制弹窗」而不是「自动排队」——所以还要配合「设置 → 通用 → 质量：分辨率上限」，
  否则每次仍会弹格式选择框。完整清单见设置页「Downie → 使用前必做」。
- **Downie 后端**是异步的：脚本侧只能确认「已入队」，无法知道下载是否完成。
  所以这类任务进「已交给 Downie」状态，实际进度要去 Downie 里看；确认文件下好后
  在队列里点「已下载，标记完成」，此时才转为「已完成」。确认前**不会从 links.txt 删行**，
  也不会自动重试；需要重新交给 Downie 时点「重新下载」。
- bili-dl 退出码 0 但没有产出文件时按失败处理（可重试），不再显示成「已完成」却什么都没有。
- **通知**需要用户授权；未授权时只在日志里写一条。在「设置 → 通用 → 通知」可查看系统授权状态、重新检测、请求授权或打开系统设置；系统侧改过权限后切回 App 也会自动刷新。
- **Downie 历史不能静默同步**：导出文件要用户在 Downie 里手动生成并选一次；本应用不读它的沙盒容器，也不订阅 CloudKit 变化。导入的记录表示「Downie 里下过」，不校验本机文件是否还在。
- **⌘V 只作用于主窗口**，且只认 http(s) 链接：裸 BV 号、`ftp://`、`file://`、`mailto:` 都不会触发（与「添加链接…」一致）。剪贴板里贴一整份导出 XML 会把其中所有链接入队，批量导入请用菜单里的导入入口。

---

## 排错

| 现象 | 排查 |
| --- | --- |
| 设置里「iCloud 访问」显示挂起/拦截 | 给 `/Applications/流影.app` 加完全磁盘访问权限，重启 App |
| 提示「无法读取下载目录」 | 同上；或把下载目录换到不受 TCC 保护的位置 |
| 手机写了文件但没反应 | 看日志里「监听链接文件：」的真实路径；iCloud 同步本身有延迟 |
| 画质只有 360P/480P | 没登录。检查 auth.toml 是否存在、SESSDATA 是否过期 |
| 订阅一直失败 | `liuyingctl bili smoke <某个BV>` 确认网络与登录态 |
| 找不到 bili-dl | `liuyingctl doctor` 看解析结果；确认 .app 内嵌完整，或在设置里填绝对路径 |
| 导入 Downie 记录提示「格式不匹配」 | 确认选的是 Downie 导出的 XML / CSV / TXT，不是 JSON、二进制或别的 App 配置；导出时别勾「包含预览图」 |
| ⌘V 没反应 | 确认主窗口是焦点窗口、没有弹层、光标不在输入框里，且「设置 → 通用 → 行为」的开关是开的；剪贴板里必须有 http(s) 链接 |
