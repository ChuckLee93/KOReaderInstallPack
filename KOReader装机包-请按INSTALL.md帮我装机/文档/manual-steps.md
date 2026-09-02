# 手动步骤与装机后设置

本文档覆盖两类内容：
A. 设备端需要用户点几下完成的步骤（A1 装机时已写入设备；A2/A3 为备用组件，
   默认不装，想用再手动安装）；
B. 装机完成后建议引导用户做的个性化设置。

---

## A1. FilebrowserPlus 无线传输服务（无需手动安装）

- 装机时已随核心一起写入 `koreader/plugins/`，并已在设置里打开**开机自启**——
  KOReader 启动后服务就绪，无需手动启动。
- 默认账号 `admin` / 密码 `admin12345678`，建议在插件设置里改为私人密码。
- KOReader 顶部菜单 → 扳手（工具）→ FilebrowserPlus 里可看到 Kindle 的局域网 IP
  （如 192.168.1.x）；电脑浏览器打开 `http://<IP>` 即可无线传书/管理文件。
- 注意：Kindle 休眠后该服务会随进程暂停，唤醒后若连不上，**开关一次 WiFi** 即可恢复。

## A2. KOLBooklet（备用组件，手动安装：在书库/首页直接进 KOReader，不用开 KUAL）

> 封面入口功能 KOReader / simpleUI 已自带；A2/A3 是可选的增强版（书库封面入口 +
> 自定义入口图标），默认装机流程不装，想用再按下面手动安装（需插一次 USB）。

1. 查看 Kindle 系统版本（设置 → 设备选项 → 关于）：
   - 系统 **5.15.x 及以上** → 用 `备用组件/kol-booklet/Update_KOLBooklet_hotfix_v1.5_install.bin`
   - 系统 **5.14.x 及以下** → 用 `备用组件/kol-booklet/Update_KOLBooklet_v1.5_install.bin`
2. USB 连接 Kindle，把对应的 bin 文件复制进 Kindle 根目录的 `mrpackages/` 文件夹
   （没有就新建）。
3. 断开 USB 后，进入 KUAL → Helper → **install MR Packages**，运行完成。
4. 之后 Kindle 书库（Library）里会出现「KOReader」入口。

## A3. Cover Setter（备用组件，手动安装：给 KUAL / KOReader 的书库入口换封面图标）

1. USB 连接 Kindle，把 `备用组件/cover-setter/CoverSetter/` 整个文件夹复制进
   Kindle 根目录的 `extensions/` 下。
2. 断开 USB 后在 Kindle 上打开 **Cover Setter**（书库里的入口或 KUAL），
   点「Set KUAL cover」和「Set KOL cover」。
3. 想换自定义封面：自制与原图同尺寸的 jpg，按原文件名替换即可。

---

## B. 装机后个性化设置（WorkBuddy 引导用户逐项确认）

以下第 1–3、8、9 项与 INSTALL.md §8.5 的收尾五项询问对应（装机时已问过的不再重复；
若装机时已同意"作者同款设置同步"，第 4–7 项里的大多数也已经是作者配置好的状态）。

1. **FilebrowserPlus 密码**：若还在用默认密码，改为私人密码。
2. **zlibrary 登录**：KOReader 扳手菜单 → zlibrary → 登录自己的账号
   （本包出于隐私不包含任何人的账号凭据）。没有账号先去官网注册：
   **https://z-lib.fo**（打不开换 https://1lib.sk / https://z-library.do，
   域名经常变；插件也能自动发现可用镜像）。
3. **KOAI 的 API key**（装了 AI 助手的用户）：本插件仅支持 DeepSeek。key 获取：
   https://platform.deepseek.com 注册 → 「API Keys」创建（`sk-` 开头，只显示一次）→
   适当充值（按量计费，很便宜）。装机时 WorkBuddy 已代填进
   `plugins/koai.koplugin/ai_query.lua` 的话无需再动；需要换 key 时改该文件第 19 行
   `local API_KEY = "…"` 引号内的值即可。5 组阅读提示词预设已就位。
4. **FilebrowserPlus 自动启动**：预设里已打开开机自启，无需操作。
5. **快速验证手势**（对应预设 `disable_double_tap = false`）：
   双击屏幕左半 = 夜间模式，双击右半 = 呼出菜单；四边滑动 = 调光；双指捏合 = 全刷。
6. **词典**：随便打开一本书，长按选中词语 → 「查词典」，能命中装机时所选的词典
   （装机记录里有清单；默认推荐组 8 部，广韵/佛学等为按需选装）。
7. **休眠锁屏**（装了锁屏壁纸插件）：合上休眠后锁屏显示所选主题壁纸
   （猫猫探头/撕纸）+ 书名作者信息卡。
8. **无线传书网址收藏**：电脑浏览器打开 Kindle 屏幕上显示的网址
   （形如 `http://192.168.x.x`）即可无线传书/管理文件，不插 USB；
   建议加入浏览器收藏夹（打开网址后 `Ctrl+D`，Mac 为 `Cmd+D`）。
   条件：电脑与 Kindle 同一 WiFi，且 KOReader 运行中（已开机自启）；
   IP 变化时以屏幕显示为准，休眠唤醒后连不上就开关一次 WiFi。
9. **桌面版 Calibre**（可选，官网 https://calibre-ebook.com/download）：
   电脑上的电子书管家——书库管理、EPUB/MOBI/AZW3/PDF 格式互转、
   编辑元数据、Kindle 插 USB 后右键「发送到设备」直接传书。

---

## 常见手动排障

- **KUAL 里找不到 KOReader**：检查 `koreader/` 目录是否完整、`koreader.sh` 是否存在。
- **FilebrowserPlus 连不上**：确认电脑和 Kindle 同一 WiFi、IP 没变（路由器重启后 IP 可能变化），
  界面上重新查看 IP；仍不行就开关一次 WiFi。
- **KOLBooklet 装完没出现入口**：确认放的是 `mrpackages/`（不是 `documents/`），
  且系统版本与所选 bin 匹配。
