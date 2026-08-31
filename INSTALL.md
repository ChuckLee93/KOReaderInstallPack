# KOReader 一键装机指令（WorkBuddy 执行入口）

> **本文件是给 AI 助手（WorkBuddy）的完整装机操作手册。**
> 用户已越狱并装好 KUAL，把整个「KOReader装机包-请按INSTALL.md帮我装机」文件夹交给 WorkBuddy 后，
> WorkBuddy 按本文档从上到下顺序执行即可。执行中所有需要用户决策的地方都会用
> `【询问用户】` 标出。**全部文件操作通过 USB 直连完成**——用户唯一的手动动作是
> 把 Kindle 用 USB 线插到电脑上；WiFi 远程通道（§3）仅用于装机后的验证与日后售后。
> **开始任何装机操作前，必须先完成 §1.5 前置确认：确认机型 + 确认 KOReader 已安装。**

---

## 0. 执行原则（必读）

1. **顺序执行**：按 §1.5 → §2 → §3 → §4 → §5 → §6 → §7 → §8 → §8.5 → §9 顺序，中途失败先重试再排查（§9）。
2. **先备份后改动**：凡是要覆盖/删除的设备文件，先从 Kindle 盘复制到本机 `backup/` 目录（在装机包文件夹旁创建）。
3. **（仅装后验证/售后阶段）设备休眠会掉线**：Kindle 休眠唤醒后 WiFi 经常不自动恢复（HTTP 超时/ping 不通）。
   此时 `【询问用户】`："请唤醒 Kindle，然后**开关一次 WiFi**（菜单→飞行模式开再关），我再重试。"
   实测开关 WiFi 后 10 秒内即可恢复。
4. **所有复制都先校验**：文件复制到 Kindle 盘后**读回比对 md5**，不一致则重复制；每个请求/复制操作失败重试 3 次。
5. **不要删除 `gestures.koplugin`、`autosuspend.koplugin`、`calibre.koplugin`、`coverbrowser.koplugin`、
   `coverimage.koplugin`、`statistics.koplugin`、`batterystat.koplugin`** —— 这些是蓝本保留的插件。
6. **装机期间 KOReader 保持退出状态、USB 线保持插着**（USB 传输模式下设备不会休眠，无需防休眠）。
   WiFi 远程通道只在 §8 重启之后才使用。
7. **用户可能指定只装部分组件**（"只装几号""只装 A 和 B"）：先按 **§1.7 组件编号总表**
   确定安装清单再开工，未指定的组件一律跳过、不再询问。

---

## 1. 包结构速查

```
KOReader装机包-请按INSTALL.md帮我装机/
├── INSTALL.md                    ← 本文件（装机总指令）
├── README.md                     ← 给人类看的说明
├── 使用说明.txt                   ← 给收包人看的傻瓜版说明（是什么/怎么用/有什么）
├── manifest.json                 ← 全部文件 md5 清单（校验包完整性）
├── 推荐必装·无线传书/            ← 推荐必装（不占编号）：无线传输插件（装机时由 AI 随核心复制进设备，§2 第 7 步）
│   └── filebrowserplus.koplugin/ ← 无线传书+AI 远程排障通道
├── 0、必装核心/                  ← 必装（编号 1-6 号都在这里，自改功能核心）
│   ├── plugins/                  keepalive / zlibrary / pinyinime / vocabbuilder
│   ├── patches/                  8 个功能补丁 + 2 个诊断探针补丁（体检 + 重启抓栈）
│   ├── frontend/                 touchmenu.lua + menu_activate.lua（版本敏感！）
│   ├── settings/gestures.lua     手势配置（整文件覆盖）
│   ├── settings/settings-preset-core.lua  设置预设（键块合并，约 90 键）
│   ├── defaults.custom.lua       低内存保护（装机时询问，老机型推荐，见 C7）
│   ├── remove-plugins.txt        待删官方插件清单（26 个）
│   └── dicts/                    12 部 stardict 词典（选择安装，见 C4）
├── 7-8、界面美化与锁屏壁纸/     ← 选装（7 号 + 8 号）：美化界面包（simpleUI + 6 款字体 + 4 美化补丁）
│                                   与锁屏壁纸插件（分别询问，见 D1 / D2）
├── 9、生僻字注音/                ← 选装（9 号）：生僻字注音插件 v2.1（含 使用说明.txt；数据文件 7 个随包，繁体书模式新增 4 个）
├── 10、AI 伴读/                  ← 选装（10 号）：KOAI 阅读助手（无 API key，装机时引导获取）
├── 11、翻页动画/                 ← 选装（11 号）：翻页动画（仅 KPW5+ 新机型有动画效果；native/ 新机型用，software/ 老机型备用默认不装）
├── 12、蓝牙外接键盘/             ← 选装（12 号）：蓝牙/外接键盘插件（externalkeyboard）
│                                   + SSH 远程连接（组合选装，见 D6）
├── 13、觅阅·微信读书/            ← 选装（13 号）：觅阅·微信读书客户端（miuread.koplugin）
├── 14、番茄阅读/                 ← 选装（14 号）：番茄阅读（fanqie.koplugin，番茄小说客户端 v2.2.1）
├── 备用组件/                     ← 备用（默认装机流程不安装）：KOReader/KUAL 封面增强（KOLBooklet、cover-setter）
└── 文档/
    ├── manual-steps.md           ← 手动步骤与装机后设置
    └── rollback.md               ← 回滚指南
```

---

## 1.5 装机前置确认（先于一切装机操作）

按顺序完成两项确认，任何一项不通过就先处理，**不要直接开始装机**：

### 1.5.1 确认机型

`【询问用户】`："你的 Kindle 具体是什么型号？（如 PW2/PW3/PW4/PW5……，哪一年买的）"

- 机型决定三件事：
  - §6-D5 翻页动画：仅 KPW5 及以上新机型有动画效果，老机型跳过该项；
  - §4-C7 低内存保护：老机型（KPW4 及更早）推荐启用，新机型不推荐；
  - 若 KOReader 未安装（§1.5.2），该下载哪个官方安装包变体。
- 用户说不清时：让其查看 Kindle 设置 → 设备选项里的型号，或报出序列号前缀（B0xx）由
  WorkBuddy 检索判断。
- 判据（与 §2 机型门一致）：**2021 年 10 月后发布的机型（PW5/PW6/PW11/PW12
  及 MTK 平台）= 新机型**；之前的老机型（PW2/PW3/PW4/KV/KO 等，即 KPW4 及更早）= 老机型。

### 1.5.2 确认 KOReader 是否已安装

`【询问用户】`："设备上装了 KOReader 吗？（打开 KUAL 菜单，里面有没有 KOReader 这一项）"

- **已安装** → 记下用户的机型回答，然后**必须询问一次是否替换为本包改良版**（见 §1.5.3）：
  - 用户同意替换 → 按 §1.5.3 执行替换，替换完成后回到 §2 从第 2 步继续（走全量装机）。
  - 用户想保留现有 KOReader → 尊重选择，直接进入 §2 USB 连接（在现有版本上
    叠加装机；此时按 §1.7 部分安装规则处理，§7 精简默认不执行；对方原有的
    定制/插件布局可能与本包冲突，装机前提醒对方先看 §2 第 6 步的备份）。
- **未安装** → 先按以下步骤装 KOReader，装好并确认能启动后再继续：
  1. 前提：设备已越狱且装有 KUAL。**越狱不在本包范围内**——若设备未越狱，
     先让用户自行完成越狱 + KUAL 安装，再回来继续。
  2. 从 KOReader 官方 GitHub Release（https://github.com/koreader/koreader/releases）
     下载 **v2026.07.1 或更新版本**、对应机型的 zip（本包要求 ≥v2026.07.1，这是
     翻页动画插件的最低版本要求）：
     - PW2 及之后的大多数机型（PW2/PW3/PW4/KV/KO 等）→ `koreader-kindlepw2-v<版本>.zip`
     - 更老的触屏机型（Touch/PW1）→ `koreader-kindle-v<版本>.zip`
     - 高频 PWM 背光老机型 → `koreader-kindlehf-v<版本>.zip`
     - 非常老的机型 → `koreader-kindle-legacy-v<版本>.zip`
  3. 指导用户按 §2 第 1 步插好 USB 线，WorkBuddy 自己把 zip 解压出的 `koreader/`
     和 `extensions/` 两个文件夹复制到 Kindle 盘根目录（即设备的 /mnt/us 下，与
     documents 平级；已存在的 koreader 文件夹直接合并覆盖）。
  4. 安全弹出 USB，KUAL → KOReader → Start KOReader。`【询问用户】`："启动成功了吗？"
     启动正常 → 请用户**重新插回 USB 线**，回到 §2 从第 2 步继续完成装机；
     失败 → 排查越狱/KUAL 状态后重试。

### 1.5.3 推荐替换为本包改良版（对方已装有 KOReader 时）

**触发**：§1.5.2 确认对方已装有 KOReader（无论版本新旧、是否自己调过）。
此时**必须询问一次**，话术如下（可按对话上下文微调，意思不变）：

> 你设备上已经装了 KOReader。**建议换成这个装机包里的改良版**——同样基于
> 官方版本，但做了一轮系统性调校：
>
> · **精简**：删掉 20 多个用不到的官方插件和多余菜单项，界面清爽、菜单好找、
>    内存占用也更低；
> · **修复**：改好了官方版里的几个已知问题（比如保活开了还是会休眠、词典
>    查词时没法把词加进生词本、生僻字注音会读错多音字等）；
> · **内置诊断**：装了两枚"体检探针"——平时无感，出问题时能自动生成设备
>    状态报告、自动抓出重启的元凶，找人帮忙时发个文件就能远程排查；
> · **即装即用**：简洁界面、完整手势方案、快速设置、随包词典，装完直接好用。
>
> 要换成改良版吗？——换的话做**覆盖安装**，你的书、生词本、词典都不会丢；
> 不换也行，我就在你现有版本上叠加安装，但上面这些修复和优化就没有了，
> 个别组件可能受你原有配置影响用不上。

**对方选"换"（推荐路径）**：
1. 先按 §2 第 6 步备份对方 `koreader/` 里的设置类文件（尤其对方自己调过配置时）；
2. 按 §1.5.2 未安装分支的第 2~4 步：下载官方 **v2026.07.1 或更新**对应机型 zip，
   覆盖合并到设备（覆盖安装保留 settings、词典、生词本数据，只更新程序本体）；
3. 覆盖完成后回到 §2 从第 2 步走**全量装机**（含 frontend 覆盖、插件修复替换、
   双探针、手势；此路径下 §7 精简默认执行，因为底座已换成本包基线）。

**对方选"不换"**：回到 §1.5.2 已安装分支的保留路径（§2 + §1.7 部分安装规则）。

---

## 1.7 部分安装（用户指定只装部分组件时执行）

**触发**：用户的装机指令或装机过程中明确表示只要部分组件，例如
"请按 INSTALL.md 帮我装机，只装 1、5、8、14 号"或"只装锁屏壁纸和番茄"。
（编号总表已印在《使用说明.txt》《README.md》《装机包完整介绍.md》里，四份文档编号一致，勿改动。）

**组件编号总表（1–14）**：

| 编号 | 组件 | 默认状态 | 对应步骤 |
|---|---|---|---|
| 1 | Z-Library 搜书下载 | 必装 | C1 |
| 2 | 12 部词典（装时挑） | 必装 | C4 |
| 3 | 完整手势 | 必装 | C5 |
| 4 | 阅读小票（胶片版） | 必装 | C2（其中 1 个补丁） |
| 5 | 诊断探针（体检 + 重启抓栈） | 必装 | C2（其中 2 个补丁） |
| 6 | 拼音输入 | 必装 | C1（pinyinime） |
| 7 | 界面美化 | 询问 | D1 |
| 8 | 锁屏壁纸 | 询问 | D2 |
| 9 | 生僻字注音 | 询问 | D3 |
| 10 | AI 伴读 KOAI | 询问 | D4 |
| 11 | 翻页动画 | 询问 | D5（仅新机型） |
| 12 | 蓝牙/外接键盘（含 SSH 配套） | 询问 | D6 |
| 13 | 觅阅·微信读书 | 询问 | D8 |
| 14 | 番茄阅读 | 询问 | D9 |

**执行规则**：

1. 只装用户指定的编号/名称，**其余组件一律跳过，且不再出现在 §6 的询问里**。
2. **核心底座不占编号、默认仍装**：keepalive、FilebrowserPlus（无线传书+售后通道）、
   界面覆盖文件（C3）、核心设置合并（C6）是其余组件的运行基础，默认随装；
   用户点名不要的按其指示跳过。
3. 词典（2 号）被选中时仍走 C4 挑选流程；未选则整个 C4 跳过。
4. 阅读小票（4 号）、诊断探针（5 号）是 C2 里的独立补丁，可单独跳过。
   **5 号探针建议尽量保留**（售后远程排查全靠它）；用户明确拒绝则不装，
   并在 E5 售后说明中把远程通道一段改为"仅 USB"。
5. **部分安装时 §7（删除 26 个官方插件）默认不执行**——对方设备可能已有自己的
   插件布局；仅当用户明确说"帮我精简/删掉多余官方插件"时才执行。
6. 翻页动画（11 号）仍过机型门（仅新机型）；低内存保护（C7）不属编号组件，
   仍按机型单独询问（用户不想被问就跳过）。
7. 收尾四项（§8.5）只问与所装组件相关的：E1 仅当装了 1 号；E2 仅当装了 10 号；
   E3 只要装了底座 FilebrowserPlus 就问；E4 照旧。
8. 编号或名称模糊（如"锁屏"对应 8 号还是别的）时，先向用户复述清单确认再动手。

---

## 2. USB 连接与设备识别（用户唯一手动动作 = 插线）

1. `【询问用户】`："请用 USB 线把 Kindle 插到这台电脑上。Kindle 弹出选项的话选
   「传输文件」。KOReader 正在运行的话，先在菜单里退出（回 KUAL 或 Kindle 界面都行）。"
2. WorkBuddy 扫描本机盘符，找到 Kindle 盘：
   - 判据：根目录下有 `koreader/` 文件夹（已装 KOReader）；
     或根目录同时有 `documents/` 与 `system/`（Kindle 存储，KOReader 未装）。
   - 扫不到就 `【询问用户】`："资源管理器里 Kindle 显示的盘符是哪个？（如 E:）"
   - 找到后记为 `K:`。**下文所有 `K:/koreader/...` 即设备的 /mnt/us/koreader/...**。
   - 装机期间保持 USB 一直插着（USB 传输模式下设备不会休眠，无需防休眠）。
3. 读 `K:/koreader/version.log` 取**最后一行**，格式：
   `日期, 时间, 版本, 机型`，例如 `2026-08-17, 05:16:27, v2026.07.2, KindlePaperWhite4`。
4. **版本门**：记录设备版本。
   - **≥ `v2026.07.1`（含 v2026.07.1 / v2026.07.2 及更新）** → 全量安装（含 frontend 覆盖文件）。
     说明：v2026.07.1 是翻页动画插件（§6-D5）的官方最低版本要求，本包以此为门槛；
     界面覆盖文件在 2026.07 系列上验证过。
   - 低于 `v2026.07.1` → `【询问用户】`："你的 KOReader 是 vX，本包要求 v2026.07.1 及以上
     （翻页动画插件的最低版本要求），界面覆盖文件也只在 2026.07 系列验证过。
     推荐：我先把你的 KOReader 升级到最新版（下载官方安装包后按 §1.5.2 覆盖安装）；
     或者：跳过 3 个版本敏感文件（§4-C3 与 §6-D5 软件动画的 uimanager）且不装翻页动画，
     其余照装，个别功能可能缺失。"
     用户选跳过时，标记 `skip_frontend = true`。
5. **机型门**：记录 version.log 里的机型名，用于 §6-D5 翻页动画（是否询问）
   与 §4-C7 低内存保护推荐（老机型推荐 / 新机型不推荐）：
   - `KindlePaperWhite5`、`KindlePaperWhite6`、更新的机型（2021 年后发布的 PW5/PW6/PW11/PW12 等，以及 MTK 平台设备）→ **新机型**（有翻页动画；低内存保护不推荐）
   - `KindlePaperWhite2/3/4`、KV、KO 等老机型 → **老机型**（无翻页动画；低内存保护推荐）
   - 机型名不在上述范围或拿不准 → `【询问用户】`："你的 Kindle 是哪一年的型号？"（2021 年 10 月后发布 = 新机型）
6. **备份**：在装机包旁创建 `backup/` 目录，从 `K:/koreader/` 复制以下设备原文件（存在才备份）：
   - `settings.reader.lua`、`settings/gestures.lua`、`settings.reader.lua.old`
   - `settings/simpleui/sui_settings.lua`、`settings/customisablesleepscreen.lua`、
     `settings/customisablesleepscreen_presets.lua`、`settings/KOAI_settings.json`
   - `defaults.custom.lua`、`patches/` 目录清单、`plugins/` 目录清单（列出名字即可）
7. **装入 FilebrowserPlus**（装后验证与日后无线传书/远程售后的通道，随核心必装）：
   把 `推荐必装·无线传书/filebrowserplus.koplugin/` 整个文件夹复制到 `K:/koreader/plugins/`
   （开机自启已在 C6 设置预设里打开，无需用户任何操作）。

---

## 3. WiFi 远程通道（装机后验证与售后用；装机阶段不使用）

本通道在 §8 重启 KOReader **之后**才可用：设备连上 WiFi（与电脑同一网络）、
KOReader 启动后 FilebrowserPlus 自动开始服务（已设开机自启）。首次使用时
`【询问用户】`："KOReader 屏幕上显示的 IP 地址是多少？（形如 192.168.x.x）"
默认账号 `admin`，密码 `admin12345678`（建议引导用户修改）。

设 `BASE = http://<设备IP>`，所有设备路径以 `/mnt/us/koreader` 为 KOReader 根目录。

| 操作 | 请求 |
|---|---|
| 登录 | `POST {BASE}/api/login`，JSON body `{"username":"admin","password":"<密码>"}` → 响应 `token` 字段 |
| 鉴权 | 之后所有请求加 Header `X-Auth: <token>` |
| 列目录 | `GET {BASE}/api/resources/mnt/us/koreader/<子路径>/` → `items[]`（`name`/`isDir`/`size`） |
| 下载 | `GET {BASE}/api/raw/mnt/us/koreader/<子路径>` |
| 上传文件 | `PUT {BASE}/api/resources/mnt/us/koreader/<子路径>?override=true`，body 为文件二进制 |
| 创建目录 | `POST {BASE}/api/resources/mnt/us/koreader/<目录路径>`（PUT 不会自动建目录时先调它） |
| 删除 | `DELETE {BASE}/api/resources/mnt/us/koreader/<子路径>` |

注意：
- URL 里的中文/空格要 percent-encode。
- 上传含子目录的插件时，**逐文件** PUT（PUT 一次一个文件；父目录不存在会失败，先 POST 建目录）。
- 每个请求设 30s 超时，失败重试 3 次；连续失败按 §0 第 3 条处理（唤醒 + 开关 WiFi）。

---

## 4. 核心安装（必装，按 C1→C7 顺序）

统一说明：下文「上传 X → Y」指把 X 下的**全部文件递归复制**到 Kindle 盘的 Y 路径
（`K:/koreader/...`，盘符见 §2），逐文件复制，完成后读回 md5 校验（§0 第 4 条）。
文中出现的设备路径 `/mnt/us/koreader/...` 一律对应 Kindle 盘上的 `K:/koreader/...`。

### C1. 核心插件（4 个）
```
0、必装核心/plugins/keepalive.koplugin           → /mnt/us/koreader/plugins/keepalive.koplugin
0、必装核心/plugins/zlibrary.koplugin            → /mnt/us/koreader/plugins/zlibrary.koplugin
0、必装核心/plugins/pinyinime.koplugin           → /mnt/us/koreader/plugins/pinyinime.koplugin
0、必装核心/plugins/vocabbuilder.koplugin        → /mnt/us/koreader/plugins/vocabbuilder.koplugin
```
（`pinyinime` 是拼音输入法（作者 Merpyzf，v1.2.0，全拼/混拼/双拼，含约 170MB
万象词库），属于核心输入体验，必装。**注意**：若对方设备上已装有旧的
`pinyin_enhancement.koplugin`，必须先删除该旧目录再装本插件——两者同时启用
会冲突闪退（删除前如对方要求保留，可先改名备份）。
`vocabbuilder` 为 KOReader 官方生词本插件（本包仅微调词典窗口按钮渲染），
供 9 号生僻字注音的"生词本联动"及词典查词加生词本使用；**不在 §7 删除清单**，
随核心静默安装，无需向用户特别介绍、不占组件编号。）

### C2. 功能补丁与诊断探针（8 + 2 个）
```
0、必装核心/patches/*.lua → /mnt/us/koreader/patches/
```
文件清单：`2-book-receipt-shortcut-and-lockscreen.lua`、`2--disable-all-CB-widgets.lua`、
`2-disable-wikipedia.lua`、`2-menu-activation-split.lua`、`2-quick-settings-v9.lua`、
`2-reader-covermode-V3.lua`、`2-reading-insights-popup.lua`、`2-reading-stats-popup.lua`，
以及两个诊断探针：
- `2-diag-probe.lua`（ChuckLee93 原创）：启动后 1 秒首写、之后每 30 分钟
  把设备状态（机型/版本/电量/内存/插件/补丁/词典/设置键名/crash.log 末 80 行）
  刷新到设备 `koreader/diag_report.txt`，供用户日后求助时远程排障（见 §8.5-E5、§9）。
- `2-restart-diag.lua`（ChuckLee93 原创）：重启抓栈探针——每次 KOReader 退出/重启发生的
  那一瞬间，把发起方的完整调用栈写进 `crash.log`（搜 `[RestartDiag]` 定位元凶）。
  与 `2-diag-probe.lua` 互补：前者是每半小时的"体检快照"，后者是重启瞬间的
  "事故记录"；平时零开销，只在退出/重启那一刻动笔。
两个探针均只读不写配置、不含账号密钥，随核心必装，无需询问。

### C3. 界面覆盖文件（2 个，版本敏感）
`skip_frontend = true` 时跳过本步。
```
0、必装核心/frontend/ui/widget/touchmenu.lua        → /mnt/us/koreader/frontend/ui/widget/touchmenu.lua
0、必装核心/frontend/ui/elements/menu_activate.lua  → /mnt/us/koreader/frontend/ui/elements/menu_activate.lua
```
这两个文件实现了「菜单搜索修复」和「菜单激活拆分（顶部点按/底部滑动分激活）」。
**覆盖前必须已备份原文件（§2 第 6 步）。**

### C4. 词典（选择安装，12 部 stardict，全装约 146MB）

查词是核心功能，词典必装，但**装哪几部由用户选择**。装前 `【询问用户】`
（可多选；默认推荐勾选「常用组」整组）：

```
【询问用户】词典要装哪些？（可多选）
【推荐·常用组】—— 日常阅读查词基本够用：
  1. 现代汉语词典        —— 日常中文词语主力词典
  2. 牛津现代英汉双解     —— 英文阅读主力词典
  3. 朗道英汉字典5.0      —— 英查中（轻量快速）
  4. 朗道汉英字典5.0      —— 中查英
  5. 中华成语大词典       —— 成语典故
  6. 古汉语常用字字典     —— 读古文常用字释义
  7. 汉语大词典（离线版） —— 大而全的中文学术词典
  8. 诗词典故词典         —— 诗词意象/典故出处
【按需选装】—— 专业/兴趣向，不是所有人必须：
  9. 廣韻          —— 中古音韵（音韵学/方言研究）
  10. 廣韻反查     —— 广韵按读音反查字（配合廣韻用）
  11. 康熙字典文字版 —— 古字/生僻字检索
  12. 佛光大辞典    —— 佛学名词（读佛经/佛学文献）
```

按用户选择上传（每部词典一个文件夹，含 .ifo/.idx/.dict.dz 等，保持目录结构整体上传）：
```
0、必装核心/dicts/stardict-xiandaihanyucidian_fix-2.4.2 → /mnt/us/koreader/data/dict/stardict-xiandaihanyucidian_fix-2.4.2
0、必装核心/dicts/stardict-oxford-gb-2.4.2              → /mnt/us/koreader/data/dict/stardict-oxford-gb-2.4.2
0、必装核心/dicts/stardict-langdao-ec-gb-2.4.2          → /mnt/us/koreader/data/dict/stardict-langdao-ec-gb-2.4.2
0、必装核心/dicts/stardict-langdao-ce-gb-2.4.2          → /mnt/us/koreader/data/dict/stardict-langdao-ce-gb-2.4.2
0、必装核心/dicts/stardict-chengyuda-2.4.2              → /mnt/us/koreader/data/dict/stardict-chengyuda-2.4.2
0、必装核心/dicts/stardict-ghycyzzd-2.4.2               → /mnt/us/koreader/data/dict/stardict-ghycyzzd-2.4.2
0、必装核心/dicts/stardict-chibigenc-2.4.2              → /mnt/us/koreader/data/dict/stardict-chibigenc-2.4.2
0、必装核心/dicts/stardict-poemstory-2.4.2              → /mnt/us/koreader/data/dict/stardict-poemstory-2.4.2
（按需）0、必装核心/dicts/stardict-guangyun-2.4.2        → /mnt/us/koreader/data/dict/stardict-guangyun-2.4.2
（按需）0、必装核心/dicts/stardict-gyfancha-2.4.2        → /mnt/us/koreader/data/dict/stardict-gyfancha-2.4.2
（按需）0、必装核心/dicts/stardict-kangxitext-2.4.2      → /mnt/us/koreader/data/dict/stardict-kangxitext-2.4.2
（按需）0、必装核心/dicts/stardict-foguangdacidian-2.4.2 → /mnt/us/koreader/data/dict/stardict-foguangdacidian-2.4.2
```
用户全不选时提醒："查词功能需要至少一部词典，建议至少装现代汉语词典+牛津双解。"
装完记录实际安装清单，§8 验证时按此清单核对。

### C5. 手势配置（整文件覆盖）
```
0、必装核心/settings/gestures.lua → /mnt/us/koreader/settings/gestures.lua
```
蓝本完整手势：四边滑动=调光、捏合=全刷、张开=书库搜索、双击左=夜间模式、
双击右=显示菜单、长按左下角=目录、长按右下角=快速查看盒、全套 multiswipe 等。
整文件覆盖，无需合并。

### C6. 核心设置合并（键块合并，见 §5 算法）
读取 `0、必装核心/settings/settings-preset-core.lua`（约 90 键），按 §5 合并进设备
`settings.reader.lua` 后上传。含：翻页返回方式、菜单激活方式（`activate_menu` /
`activate_menu_top`）、双击手势开关（`disable_double_tap = false`）、
阅读统计、快速设置、zlibrary 界面、FilebrowserPlus 开机自启等。

### C7. 低内存保护（【询问用户】是否启用）

来源：觅阅 miuread 自带的推荐配置（非本包自研）。
这是一项独立的 KOReader 全局设置，**不装觅阅插件也可单独启用**，二者互不依赖。
内容为 `DGLOBAL_CACHE_FREE_PROPORTION = 0.15`（把页面缓存预算压到 0.15，
给系统后台让内存，老设备防卡死崩溃）。

装机到这里时 `【询问用户】`：

```
【询问用户】要启用低内存保护吗？（把缓存预算调小，给系统让内存，防老设备崩溃）
- 老机型（KPW4 及更早）→ 推荐启用
- 新机型（KPW5 及以后）→ 不推荐（内存充足，压缓存反而可能降低翻页流畅度）
```

- **启用** → 复制 `0、必装核心/defaults.custom.lua` 到 `K:/koreader/defaults.custom.lua`。
  若设备已有自己的 `defaults.custom.lua` 且含其他自定义项：备份后**追加**该键
  而不是覆盖；没有或只有这一个键则直接覆盖。
- **不启用** → 跳过，不复制该文件（设备上原有的 `defaults.custom.lua` 不动）。

---

## 5. settings.reader.lua 键块合并算法（精确规范）

设备 `settings.reader.lua` 格式：`return {` 开头，顶层键为 4 空格缩进的
`    ["key"] = value,` 行；多行 table 值（嵌套）从下一行开始、缩进更深，
直到下一个顶层键行或结尾 `}`。

合并步骤（preset → device）：

1. 读出设备 `K:/koreader/settings.reader.lua`（记为 `D`），解析出顶层键列表与其行区间：
   顶层键行匹配 `^    \["[A-Za-z_0-9]+"\] =`，键区间 = 该行到下一个顶层键行（或结尾 `}`）之前。
2. 解析 preset 文件（同为 `return {…}` 格式），得到每个键的**块**（含全部嵌套行）。
3. 对 preset 中每个键：
   - `D` 中有同名键 → 整块替换（删旧块，在原位置插入 preset 块）；
   - `D` 中没有 → 在结尾 `}` 之前追加 preset 块。
4. preset 未涉及的键**一律不动**（保留目标设备自己的书架、历史等）。
5. 语法校验：合并结果用 Lua 解析器验证（node luaparse 或 `luac -p`；注意 LuaJIT 的
   `continue`/`goto` 在设备上合法，校验器报这两类错可忽略）。
6. 校验通过 → 写回 `K:/koreader/settings.reader.lua`。失败 → 回滚 `D` 原文，报告错误，停止。

该算法同样适用于 §6 的 beauty / pinyin / animation 预设（各自独立执行一次合并）。
**注意**：先做 C6（core），选装部分在用户确认后再追加合并，每次合并都基于设备上最新版本重新读出。

---

## 6. 选装组件（【询问用户】八项，一次问清，可多选；已按 §1.7 指定部分安装的用户，未指定的项直接跳过不问）

向用户逐项描述功能后询问要装哪些（描述词直接使用下面括号里的说明）：

```
【询问用户】以下选装组件要装哪些？（可多选）
1. 蓝牙/外接键盘组合（externalkeyboard + SSH）—— 外接蓝牙翻页器
   （翻页遥控器）用的，插上就能实体按键翻页（也可接蓝牙键盘在
   KOReader 里打字）；组合内含 SSH 远程连接，供蓝牙翻页器使用
   （翻页器的配对与配置要在设备终端上操作，SSH 让电脑不插线就能
   远程连进 Kindle 干这些活）。两个组件一起装、一起不装
2. 生僻字注音插件 —— 阅读时自动给生僻汉字标注拼音，读古籍/生僻文本更省力
3. 翻页动画插件 —— KPW5 及以上机型才有的翻页动画效果，增加阅读沉浸感
   （老机型（KPW4 及更早）没有此效果，机型门已判定为老机型时直接告知
   "你的机型没有翻页动画效果"，跳过此项，不再询问）
4. 锁屏壁纸插件 —— 休眠锁屏变成自定义壁纸 + 书名/作者/进度信息卡
   （两种主题二选一：猫猫探头 / 撕纸）
5. AI 插件 KOAI —— 划词 AI 解析：学术概念、英语翻译、人文历史、古文典籍、
   语境赏析五套提示词，还有阅读复盘/人物卡片等精读功能（需自备 DeepSeek API key）
6. 美化界面包 —— simpleUI 卡片式书库主页 + 6 款中文字体 + 4 个美化补丁
7. 觅阅·微信读书 —— 在 KOReader 里读微信读书的书、同步阅读进度
   （装好后用微信读书账号在插件里登录，凭据只存你的设备）
8. 番茄阅读 —— 在 KOReader 里直接读番茄小说：扫码登录同步书架/进度，
   支持段评气泡、预下载和整本缓存离线读
   （首次使用用手机番茄小说 App 扫个码即可，无需配置 Cookie）
```

（封面入口功能由 KOReader / simpleUI 自带，属必装范围，**不询问、不单独介绍**；
`备用组件/` 里的 KOLBooklet、cover-setter 仅作为备用组件保留在包内，
默认装机流程不安装。）

### D1. 美化界面包（simpleUI + 字体 + 美化补丁，约 90MB）
```
7-8、界面美化与锁屏壁纸/simpleui.koplugin                   → /mnt/us/koreader/plugins/simpleui.koplugin
7-8、界面美化与锁屏壁纸/patches/*.lua                       → /mnt/us/koreader/patches/   （4 个美化补丁）
7-8、界面美化与锁屏壁纸/fonts/*/<*.ttf>                     → /mnt/us/koreader/fonts/     （12 个 ttf 平铺，不带文件夹）
7-8、界面美化与锁屏壁纸/settings/simpleui/sui_settings.lua  → /mnt/us/koreader/settings/simpleui/sui_settings.lua（整文件覆盖）
7-8、界面美化与锁屏壁纸/settings/simpleui/sui_wallpapers/wallpaper1.png → /mnt/us/koreader/settings/simpleui/sui_wallpapers/
```
最后把 `7-8、界面美化与锁屏壁纸/settings/settings-preset-ui.lua`（5 个键块，含 visual_overhaul_cover 28 键）
按 §5 合并进 settings.reader.lua。
（sui_settings 已剔除个人书单与阅读状态数据。）
字体 6 款：白桃乌龙甜茶、仓耳玄三、冰橘皮旧胶片、文鼎书苑宋、汉仪空山楷、爱像突如其来的雨。

### D2. 锁屏壁纸插件（customisablesleepscreen）

锁屏壁纸参数随主题不同，本包已内置两套参数模板，装前 `【询问用户】`：

```
【询问用户】锁屏壁纸主题选哪个？（决定壁纸图和信息框位置参数）
1. 猫猫探头 —— 猫猫从屏幕上方探头，信息框在左上角
2. 撕纸     —— 撕纸效果，信息框在左侧居中
```

| 主题 | 壁纸图文件（在插件 wallpapers/custom/ 内） | 信息框参数（已写进模板） |
|---|---|---|
| 猫猫探头 | `Image_1786627709032_919.png` | 位置 top_left，水平偏移 25，垂直偏移 -20，宽度 35%，不透明度 100%，文本居中，无图标，背景叠加 0 |
| 撕纸 | `charles_torn.png` | 位置 middle_left，水平偏移 75，垂直偏移 60，其余同猫猫探头 |

上传清单：
```
7-8、界面美化与锁屏壁纸/customisablesleepscreen.koplugin    → /mnt/us/koreader/plugins/customisablesleepscreen.koplugin
  （含 wallpapers/custom/ 两张候选壁纸，都随插件目录上传，选完主题后删掉未选中那张，见下）
选「猫猫探头」：7-8、界面美化与锁屏壁纸/settings/customisablesleepscreen.lua
         → /mnt/us/koreader/settings/customisablesleepscreen.lua（整文件覆盖）
选「撕纸」：7-8、界面美化与锁屏壁纸/settings/customisablesleepscreen-torn.lua
         → 上传时重命名为 /mnt/us/koreader/settings/customisablesleepscreen.lua（整文件覆盖）
7-8、界面美化与锁屏壁纸/settings/customisablesleepscreen_presets.lua → /mnt/us/koreader/settings/customisablesleepscreen_presets.lua（整文件覆盖）
```

**按所选主题删除未选中的壁纸**（壁纸机制是 folder 类型随机取图，custom 目录里只能留
所选那一张，否则锁屏会在两主题间随机切换）——复制插件目录后，在
`K:/koreader/plugins/customisablesleepscreen.koplugin/wallpapers/custom/` 里删除未选中的那张：
- 选猫猫探头 → 删 `charles_torn.png`
- 选撕纸 → 删 `Image_1786627709032_919.png`

最后把 `7-8、界面美化与锁屏壁纸/settings/settings-preset-sleepscreen.lua`（13 个 screensaver_* 键）
按 §5 合并进 settings.reader.lua（接管休眠屏，交由 customisablesleepscreen 渲染）。
presets 文件里 `last_loaded_preset` 必须保持 `"Default"`：内置 preset 名（如 "Kobo"）
会在插件启动时整体覆盖上面的自定义键，导致二选一参数失效。

### D3. 生僻字注音
```
9、生僻字注音/pinyin.koplugin → /mnt/us/koreader/plugins/pinyin.koplugin
```
再把 `9、生僻字注音/settings-preset-pinyin.lua`（5 键）按 §5 合并。

### D4. AI 助手 KOAI
```
10、AI 伴读/koai.koplugin           → /mnt/us/koreader/plugins/koai.koplugin
10、AI 伴读/KOAI_settings.json      → /mnt/us/koreader/settings/KOAI_settings.json
```
**不**做设置合并（KOAI 配置独立文件）。历史记录（KOAI_history.json）不随包分发。

**装机时必须引导用户获取并填入 DeepSeek API key**（本插件仅支持 DeepSeek，
包内 `koai.koplugin/ai_query.lua` 第 19 行是占位符 `输入API密钥`，不填 AI 功能不可用）：

1. `【询问用户】`："KOAI 只用 DeepSeek 的接口。你有 DeepSeek 的 API key 吗？"
2. **已有 key** → 直接进入第 4 步。
3. **没有 key** → 引导获取（发给用户）：
   - 手机/电脑浏览器打开 DeepSeek 开放平台：**https://platform.deepseek.com**
   - 注册/登录账号（与 DeepSeek 聊天网页版账号通用）
   - 左侧「API Keys」→「创建 API key」，得到一串 `sk-` 开头的密钥（**只显示一次，先复制保存**）
   - 左侧「充值」预存少量金额即可（按量计费，划词解析一条通常不到 1 分钱）
4. **填 key（WorkBuddy 代填，无需用户改文件）**：
   - 复制 `10、AI 伴读/koai.koplugin/ai_query.lua` 到本机**临时文件**，把第 19 行
     `local API_KEY = "输入API密钥"` 中的占位符替换为用户的 key（只改引号内内容）；
   - 语法校验后，复制 `10、AI 伴读/koai.koplugin/` 整个插件时用这份替换版（复制到设备
     `K:/koreader/plugins/koai.koplugin/ai_query.lua`），读回校验 md5。
   - key 属敏感信息：临时文件用完即删，不留在任何本机文件里；不回显完整 key（只确认首尾 6 位）。
5. 提醒用户：key 可随时在 DeepSeek 平台作废重发；设备借人前先作废或换 key。

### D5. 翻页动画（仅 KPW5 及以上机型）

来源：https://github.com/koplugin-swipe-11、翻页动画/Swipe_Animation.koplugin （v4.x）。
**要求 KOReader ≥ v2026.07.1**（§2 版本门已保证；低版本装了也不生效）。
**仅 KPW5 及以上机型（2021 年 10 月后发布的新机型 / MTK 平台）有翻页动画效果**；
老机型（KPW4 及更早）没有此效果——机型门判定为老机型时，§6 询问环节直接告知
"你的机型没有翻页动画效果"并跳过，不装。

- **新机型方案**（PW5/PW6/PW11/PW12 等 / MTK 平台，设备自带原生翻页动画）：
  官方建议：有原生动画的设备**只装 `2-pdf-animation.lua` 一个补丁**——
  仅 PDF 翻页用硬件原生动画，EPUB 交给系统原生动画，无需模拟。
  ```
  11、翻页动画/native/2-pdf-animation.lua → /mnt/us/koreader/patches/
  ```
- **software 方案**（`11、翻页动画/software/`，老机型软件模拟滑动）：
  包内仅作备用保留，默认不装；用户明确坚持要求时才按下面执行
  （提前告知：老机型上模拟动画效果有限、且 uimanager 覆盖文件版本敏感）：
  ```
  11、翻页动画/software/frontend/ui/uimanager.lua → /mnt/us/koreader/frontend/ui/uimanager.lua（版本敏感，skip_frontend 时跳过并警告）
  11、翻页动画/software/patches/*.lua → /mnt/us/koreader/patches/（3 个：pdf-animation / swipe-core / swipe-settings）
  ```
  最后把 `11、翻页动画/software/settings-preset-animation.lua`（4 键）按 §5 合并。

卸载（用户日后要求时）：官方提供 restore-files 恢复被覆盖的 frontend 文件，
再删除设备 `patches/` 下的 3 个动画补丁即可（见 文档/rollback.md）。

### D6. 蓝牙/外接键盘组合（externalkeyboard + SSH 远程连接）

KOReader 官方内置插件，蓝本设备因不用而删除，本包单独保留一份供选装。
两个插件是一组**组合**：装机时一起询问是否选装（见 §6 第 1 项）——
选 12 号 = 两个都装；不选 = 两个都不装。
```
12、蓝牙外接键盘/externalkeyboard.koplugin → /mnt/us/koreader/plugins/externalkeyboard.koplugin
12、蓝牙外接键盘/SSH.koplugin             → /mnt/us/koreader/plugins/SSH.koplugin
```
- 功能：外接蓝牙翻页器（翻页遥控器）翻页用；也可接蓝牙键盘
  在 KOReader 里用实体键盘打字。
- SSH 远程连接（官方内置插件，本包未改动）：在电脑上用 ssh 远程连进
  Kindle 的终端。**供蓝牙翻页器使用**——翻页器的配对、守护进程等配置
  需要在设备终端上操作，SSH 是不插 USB 线干这些活的通道；不用蓝牙
  翻页器的人用不到它。它依赖 KOReader 自带的 dropbear 程序（官方安装包
  已包含，无需随包分发）；SSH 服务默认不自启，需要时在 KOReader 菜单里
  开启（默认端口 2222）；**装机时不做任何 SSH 账户/密钥配置**。
- **注意**：externalkeyboard 与 SSH 都已从 §7 删除清单移除——用户选装了
  12 号则装上；未选装时若设备上本来就有它们，保持不动（不装也不删，
  尊重对方设备现状）。
- 使用提示（装完转告用户）：部分 Kindle 需要额外的 hid-passthrough 支持才能识别
  键盘，插上键盘没反应时多为系统限制，不是装机失败。

### D7.（已移除）给 KOReader 和 KUAL 加封面

封面入口功能由 KOReader / simpleUI 自带（必装范围内已包含），装机流程
**不再单独安装、不询问**。`备用组件/` 里的 KOLBooklet（bin 安装包）与
cover-setter 仅作为备用组件保留在包内：日后用户想要"书库封面入口 +
自定义入口图标"的增强版，可让 AI 参考 `文档/manual-steps.md` A2/A3 手动安装
（需再插一次 USB）。

### D8. 觅阅·微信读书（miuread）

微信读书客户端：在 KOReader 里读微信读书的书、同步阅读进度。
来源：https://github.com/miumiupy98-art/miuread-koreader（衍生自
finlater/weread.koplugin），本包收录 ChuckLee93 优化冷启动版 5.0.0。
```
13、觅阅·微信读书/miuread.koplugin → /mnt/us/koreader/plugins/miuread.koplugin
```
- **无设置合并、无配置文件**：微信读书账号由用户装好后自行在插件里登录
  （凭据只存设备端，WorkBuddy 不代填不记录）。
- 低内存保护（§4-C7）是独立的 KOReader 全局设置，与本插件互不依赖——
  不装觅阅也可启用，装了觅阅不启用也行。

### D9. 番茄阅读（fanqie.koplugin）

番茄小说客户端：在 KOReader 里直接读番茄小说——扫码登录同步书架与进度、
章节阅读、智能预下载、整本缓存离线读、段评气泡（仅大灰狼书源支持段评）、
阅读进度双向同步。
来源：https://github.com/hesan1232/fanqie.koplugin（v2.2.1，**原版收录未改动**，
2026-08-09 官方 Release，sha256 21b368198b26c2f0f874f413c001f87c94af82a2292046620fcb2207c16de86b）。
```
14、番茄阅读/fanqie.koplugin → /mnt/us/koreader/plugins/fanqie.koplugin
```
- 插件内的 `patches/core.lua` 是插件**自身模块**（随文件夹整体复制即可，
  **不要**把它单独安装到 `koreader/patches/`），由插件运行时自行打补丁。
- **装机时不做任何账号配置**：首次使用由用户在设备上完成——
  菜单 → 番茄小说 → 扫码登录，用手机番茄小说 App 扫屏幕二维码即可，
  Cookie 自动持久化，重启无需重登。想用大灰狼/晴天聚合书源（段评）的用户，
  参照插件目录里的 `config.example.lua` 自建 `config.lua` 填账号。
- 免责提示（装完转告用户）：番茄没有官方开放接口，插件依赖第三方书源，
  接口可能变动失效（历史上被封过又恢复）；届时更新插件或切换书源即可，
  属上游问题而非装机问题。

---

## 7. 精简：删除多余的官方插件（26 个）

读取 `0、必装核心/remove-plugins.txt`（每行一个插件名）。对每个名字：

1. 检查 `K:/koreader/plugins/<名字>.koplugin/` 是否存在。
2. 存在 → 先**递归复制**到本机 `backup/removed-plugins/<名字>.koplugin/`，再删除 Kindle 盘上的该目录。
3. 不存在 → 跳过（记录，无需提示）。

全删完后向用户汇报实际删除了哪几个。此步只是精简菜单，不影响核心功能。
注意：`externalkeyboard`（蓝牙/外接键盘）与 `SSH`（远程连接）都已移出删除清单
（§6-D6 的 12 号组合组件）——用户选装了 12 号时两个都装上、保持不动；
未选装且设备原有它们时**也保持不动**（询问对方是否顺带删掉）。

---

## 8. 重启与验证

1. 所有文件操作完成后，`【询问用户】`："装机文件都放进去了，请**安全弹出 USB**
   （任务栏 USB 图标 → 弹出，或资源管理器里右键 Kindle 盘 → 弹出），拔掉线。
   然后通过 KUAL → Start KOReader 启动 KOReader，启动后告诉我。"
2. 启动后引导用户逐项验证（设备端操作，WorkBuddy 口述）：
   - [ ] 扳手菜单里出现新插件（zlibrary / 生僻字注音 / KOAI / simpleUI 等）
   - [ ] 阅读中：双击屏幕左半 = 切换夜间模式；双击右半 = 呼出菜单
   - [ ] 屏幕四边滑动 = 调节亮度；双指捏合 = 全屏刷新
   - [ ] 顶部点按 / 底部滑动分别激活不同菜单（菜单激活拆分生效）
   - [ ] 查词：打开一本书选中文本 → 查词典（按 C4 记录的所选词典清单核对）
   - [ ] 选装了美化界面包：书库主页变 simpleUI 卡片式
   - [ ] 选装了锁屏壁纸：休眠锁屏显示所选主题壁纸
   - [ ] 选装了动画：翻页有滑动/淡入动画
   - [ ] 选装了蓝牙/外接键盘：插上键盘后能输入（部分机型受系统 hid 支持限制）
   - [ ] 选装了觅阅/番茄阅读：扳手菜单出现对应插件入口
     （番茄首次使用需手机 App 扫码登录，见 §6-D9）
   - 可选：若电脑与 Kindle 在同一 WiFi，WorkBuddy 可经 §3 远程通道读
     `diag_report.txt` 核对装机结果（此时提醒用户别让 Kindle 睡着）；
     不方便连 WiFi 就纯靠上面的口述清单核对。
3. 验证全部通过后，进入 **§8.5 装机后询问（收尾四项 + 售后说明）**逐项询问用户；
   更细致的个性化设置清单见 `文档/manual-steps.md` B 节。

---

## 8.5 装机后询问（收尾四项 + 售后说明，§8 验证通过后逐项进行）

装机验证完成后，WorkBuddy **主动**向用户提出以下四项收尾询问。逐项问，
每项处理完再进入下一项，不要一口气全部抛出。四项问完，最后按 E5 向用户
做售后说明（必做），之后装机流程才告结束。

### E1. Z-Library 账号

1. 先告诉用户 Z-Library 官网：**https://z-lib.fo**
   （域名经常变，打不开就换 **https://1lib.sk** 或 **https://z-library.do**；
   插件自带「自动发现可用镜像」功能，设备端打不开某个镜像时让它自动换即可）。
2. `【询问用户】`："你有 Z-Library 的账号吗（注册邮箱 + 密码）？"
   - **有** → 引导在设备上登录：KOReader 顶部菜单 → 扳手 → Z-Library → 登录，
     输入账号密码即可。账号密码**由用户在自己设备上输入**，凭据只存在对方
     Kindle 里——WorkBuddy 不代填、不记录、不写入任何本机文件。
   - **没有** → 引导注册：浏览器打开上面的官网 → 注册账号（邮箱验证）→
     注册完成后回到设备上按上面的路径登录。免费账号每天可下载若干本，
     日常阅读完全够用。
3. 若用户暂时不想注册：告知可以先用游客身份搜索/浏览，想下载时再注册登录。

### E2. AI 伴读的 API key（仅限装了 KOAI 的用户）

1. 装机时（§6-D4）**已代填过 key** → 跳过询问，只提醒一句：
   "key 可随时在 DeepSeek 平台作废重发（https://platform.deepseek.com → API Keys），
   设备借人前记得先作废。"
2. 装机时**没给 key**（当时选了跳过）→ 现在补问：
   `【询问用户】`："现在要配置 AI 伴读的 DeepSeek key 吗？"
   - 要 → 按 §6-D4 第 3–4 步流程办理：获取网址 **https://platform.deepseek.com**
     （注册 → 「API Keys」创建 `sk-` 开头密钥 → 适当充值，按量计费很便宜），
     然后 WorkBuddy 代填 `plugins/koai.koplugin/ai_query.lua` 第 19 行并回读校验。
   - 不要 → 告知日后想启用时，改设备上 `plugins/koai.koplugin/ai_query.lua`
     第 19 行引号内的值即可（或再找 AI 助手帮忙）。

### E3. 无线传书网址（装了 FilebrowserPlus 的用户——即所有装机用户）

FilebrowserPlus 在 Kindle 上开了一个网页服务，电脑浏览器打开
**Kindle 屏幕上显示的网址（形如 `http://192.168.x.x`）**，就能随时无线传书、
管理文件，从此基本不用再插 USB 线。

1. 向用户说明上面的用法，让用户**以 Kindle 屏幕当前显示的网址为准**核对一遍
   （装机时 WorkBuddy 记下的 IP 若已变化，以屏幕为准）。
2. `【询问用户】`："要把这个网址加入浏览器收藏夹吗？以后传书一键就到。"
   - 要 → 指导用户：在电脑浏览器打开该网址 → `Ctrl+D`（Mac 为 `Cmd+D`）收藏。
   - 不要 → 跳过。
3. 顺带提醒"随时能连"的两个条件：
   - 电脑和 Kindle 连**同一个 WiFi**（换了路由器/网络后 IP 可能变化，
     以 Kindle 屏幕显示的最新网址为准）；
   - Kindle 上 KOReader 在运行且服务开着（预设已开启开机自启；
     休眠唤醒后连不上时，开关一次 WiFi 即可恢复）。

### E4. 桌面版 Calibre

1. `【询问用户】`："要不要在你电脑上装一个 Calibre？免费开源的电子书管理软件。"
2. 向用户介绍用处：
   - 一句话：**电脑上的电子书管家**。
   - 具体：① 管理电脑里的电子书库（分类、搜索、封面墙）；② 各种格式互相
     转换（EPUB / MOBI / AZW3 / PDF 等，传 Kindle 前转成合适的格式和排版）；
     ③ 编辑书名、作者、封面等元数据；④ Kindle 插 USB 后右键
     「发送到设备」直接传书（和 KOReader 无线传书互补，大文件/批量更顺手）。
3. 要装 → 引导下载：**https://calibre-ebook.com/download**
   （选 Windows / macOS 版本，安装一路下一步；界面语言在
   首选项 → 界面语言 → 简体中文 切换）。装完教一句基本操作：
   把书拖进 Calibre → 选中 → 右键「转换书籍」转 EPUB → 连上 Kindle 后
   右键「发送到设备」。
4. 不装 → 告知以后需要时从官网下载即可，无其他影响。

### E5. 售后说明（四项问完后的最后一段，必做）

装机已包含**两个诊断探针**（随核心静默安装）：
- **体检探针**（补丁 `2-diag-probe.lua`）：KOReader 启动后和之后每 30 分钟，自动把
  设备状态——机型、版本、电量、内存、插件/补丁/词典清单、设置键名、crash.log
  末 80 行——写到设备上的 `koreader/diag_report.txt`。
- **重启抓栈探针**（补丁 `2-restart-diag.lua`）：每次 KOReader 退出/重启发生的那
  一瞬间，自动把发起方的完整调用栈写进 `crash.log`（搜 `[RestartDiag]` 即可定位
  是谁发起的重启）。
两个探针都只读不写配置、不含账号密钥，报告和日志只存在对方自己设备里。

向用户念这段话（可换说法，意思到位即可）：

> 装机时给你装了两个"诊断探针"：一个"体检探针"每半小时记录一次设备状态；
> 另一个"重启记录仪"会在 KOReader 退出或重启的瞬间，把是谁发起的写进日志。
> **以后使用中遇到任何问题**——比如：KOReader 崩溃退出或卡死、翻页/手势失灵、
> 查词没结果、词典或插件打不开、AI 伴读没反应、Z-Library 搜不到或下载失败、
> 电脑连不上无线传书网址、锁屏壁纸不显示、想调字体/壁纸/任何设置不会弄——
> **只要满足下面任意一条，都可以直接把问题丢给 AI 助手**：
> ① Kindle 开着 KOReader（FilebrowserPlus 已设为开机自启、运行期间常开
>    不自动关闭，和电脑同一 WiFi 时默认就是连着的）——AI 可以直接远程
>    读取诊断报告和日志，边看边修；
> ② 或者 USB 插上电脑——把 `koreader/diag_report.txt` 和 `koreader/crash.log`
>    拷出来发给 AI 也可以。
> 两条都不满足时，也可以直接描述现象，AI 会给排查建议。
> 记住一句话：**设备连得上，问题就问得出。**
>
> 还有一件事：**以后想要什么别的插件，直接告诉 AI 就行**——
> AI 会帮你从网上找到合适的、直接装进 Kindle，不需要你自己折腾。

念完后确认用户听懂，装机流程到此全部结束。

---

## 9. 故障排查

| 现象 | 处理 |
|---|---|
| **任何用户报障（装机后求助）** | 先读探针报告 `diag_report.txt`（远程通道 `GET /api/raw/mnt/us/koreader/diag_report.txt`，或 USB 插电脑直接读 `K:/koreader/diag_report.txt`；启动后 + 每 30 分钟自动刷新：机型/版本/电量/内存/插件/补丁/词典/设置键/crash.log 末段），再按报告线索定位；需要更多现场时对照读 crash.log 全文与相关插件/补丁文件。用户求助的接入方式见 §8.5-E5 |
| 扫不到 Kindle 盘符（装机阶段） | 让用户确认弹窗选了「传输文件」、KOReader 已退出；仍没有就资源管理器里人工确认盘符后告知 |
| 复制到一半失败 / 读回 md5 不符 | 大文件传输偶发；重试该文件，连续失败换 USB 口/线再试 |
| HTTP 超时 / ping 不通（远程通道） | 设备休眠或 wifid 失联 → §0 第 3 条（开关 WiFi） |
| 登录 401 | 密码错；默认 `admin/admin12345678`；让用户在插件界面确认 |
| 上传 404（远程通道） | 父目录不存在 → 先 POST 创建目录再 PUT |
| KOReader 启动即崩溃（crash.log） | 多为 frontend 覆盖文件与版本不符 → 用 `backup/` 原文件回滚 touchmenu.lua / menu_activate.lua / uimanager.lua（见 文档/rollback.md） |
| 菜单缺项 / 手势无效 | 确认 settings.reader.lua 合并成功、gestures.lua 已复制、重启过 KOReader |
| 内存不足卡死 | 确认用户启用了低内存保护（§4-C7）且 defaults.custom.lua 已复制（0.15） |
| 词典查询不到 | 确认 data/dict/ 下所选 stardict 目录完整（每部含 .ifo/.idx/.dict.dz），对照 C4 记录的所选清单 |

完整回滚方案见 `文档/rollback.md`。
