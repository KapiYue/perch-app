# Perch 执行顺序

更新日期：2026-08-14

**读法**：阶段之间是**依赖顺序**，阶段内部大致按先后排。标 🔴 的是阻塞项，不做完后面会返工。标 ⚡ 的可以和别的阶段并行。

配套文档：[发布清单](docs/release-checklist.md)（项目状态 + 市场定位 + 发版检查项）、维护者本地的备案手册 / 部署手册 / 腾讯云配置记录 / 签名与更新手册。

---

## 阶段 0 · 现在就做

- [x] ~~删除并重建 COS 桶~~ → **2026-08-14 15:38 完成**，桶名 `perch-dist-1305706023`
- [x] ~~验证公有读~~ → curl 返回 **404 NoSuchKey**（不是 403 AccessDenied），说明匿名读已生效、只是 DMG 还没上传。M6 有真包后再复验一次 200
- [x] ~~确认备案口径~~ → **2026-08-14 15:54 腾讯云工程师答复：子域名不需单独备案；macOS 桌面软件不属于移动互联网应用程序，也不需要备案。** 对话截图已存档，备案侧零待办
- [x] ~~`git init`~~ → 已完成，`.gitignore` 实测挡住了内部材料
- [ ] 🔴 **COS 生命周期加规则**：`abort-multipart-7d`，整个存储桶，只勾「删除未完成的分片上传 = 7 天」。**绝对不要勾「当前版本文件删除」。** 控制台目前仍显示「生命周期 未配置」
- [ ] 首次 commit 并推到 GitHub 仓库 `KapiYue/perch-app`
- [ ] 🔴 **确认 Apple Developer 会员到期日** —— developer.apple.com → Membership details。
      ⚠️ 同时注意：词鲸那张是 `Apple Distribution` 证书，**Perch 需要的是 `Developer ID Application`，两者不是同一类证书**，必须单独创建。同一份会员资格覆盖两者。步骤见签名手册第 1.4 节

---

## 阶段 1 · 官网上线 ⚡（可与阶段 2 完全并行）

站点五个页面已完成，备案不用新办，**不依赖 App 有没有做好**。

- [ ] 🔴 **先决定下载按钮怎么办。** DMG 要等 M6 才有，现在上线的话三处下载按钮会 404。两个选择：
      **(A) 推荐** —— 把下载区临时改成「即将发布」状态，引导去 GitHub 点 star；等 M6 换回真实链接。
      **(B)** 等 M6 完成后再一起上线，但这样 `/privacy`、`/support` 长期不可访问。
      选 A 的话这一步就是改 `site/index.html` 的下载区文案。
- [ ] DNS 加 A 记录：`perch` → `58.87.65.155`，`dig +short perch.joy-coder.com` 输出必须等于该 IP。
- [ ] 申请证书并安装到 `/etc/nginx/ssl/perch/`。
- [ ] `rsync` 上传 `site/`（排除 `serve.py`、`.DS_Store`），启用 `deploy/nginx/perch.conf`，`nginx -t` 通过后 reload。
- [ ] 公网验收：`/`、`/features`、`/privacy`、`/support`、`/credits`、两个 assets 全部 200 且 `verify=0`。
- [ ] 五个页面页脚核对：`浙ICP备2026055717号-2` + `浙公网安备33010502013311号` + 图标不裂，**没有误挂词鲸的 `-3A`**。
- [ ] ⚡ 补 `site/favicon.svg`（当前是内联 data URI，能用但换成真文件更规范）。

---

## 阶段 2 · App 开发 M0–M6

**一次只跑一段提示词，跑完手动验收再进下一段。** macOS 拖拽的问题编译期看不出来，只有真机拖一次才知道。

### M0 · 工程骨架（约 0.5 天）
- [ ] XcodeGen `project.yml` + 全部占位文件按既定目录结构生成
- [ ] 菜单栏常驻，无 Dock 图标（`LSUIElement = true`）
- [ ] `script/build_unsigned.sh` 能 ad-hoc 签名本地跑起来
- [ ] **验收**：菜单栏图标可点出菜单，Dock 里没有图标

### M1 · 面板 + 拖入 + 拖出（约 3–5 天）🔴 生死线
- [ ] `PerchPanel`（`NSPanel` + `.nonactivatingPanel`）、`HotZoneWindow`
- [ ] 拖入：多文件全部接收，拷贝进 `blobs/`，`QLThumbnailGenerator` 生成缩略图
- [ ] **拖出：`NSFilePromiseProvider` + delegate**
- [ ] **验收**：① 拖 3 个文件进去 → 切 Space → 拖进另一个 Finder 窗口，3 个都在；② 拖进浏览器上传框能上传成功；③ 面板展开时前台 App 输入光标不消失；④ 用 FilePromise 拖出一个「还不存在的文件」到桌面，文件被正确创建

> 🚨 **第 ④ 条做不通就停下来，不要绕过去继续堆功能。** 这是整个项目唯一「做不出来就废了」的能力，后面全部功能都架在它上面。

### M2 · 剪贴板监听 + 文本列表 + 单击复制（约 3 天）
- [ ] `ClipboardWatcher`：0.5s 轮询 `changeCount`，按 图片 → 文件URL → 链接 → 文本 判定
- [ ] 文本列表 UI（**不是卡片**），⌘1–9 序号，图片显示缩略图，链接绿色
- [ ] 四条取出路径全部实现
- [ ] 复制反馈只做行内，**不弹全局 toast**
- [ ] 面板头部常驻 ⏸ 暂停按钮，状态持久化
- [ ] **验收**：复制文本 → 自动上架 → 单击 → 到备忘录 ⌘V 出来；复制截图 → 显示缩略图 → 拖到聊天窗口对方收到 png

### M3 · 持久化 + 自动清理 + 去重（约 2 天）
- [ ] `index.json` 原子写（写 `.tmp` 再 rename）；**图片/文件只存路径，绝不 base64 进 JSON**
- [ ] 去重只和当前区域最新一条比，命中重置 `createdAt`
- [ ] 保存时长设置项，默认 12 小时；启动一次 + 每 60 秒扫描；固定项永不过期
- [ ] 清理条目时同步删除 `blobs/` 目录，不留孤儿
- [ ] 剪贴板上限 200 条
- [ ] **验收**：退出重开内容还在；时长设成 1 小时验证清理生效且固定项不被清；连续复制同一文本不新增只重置

### M4 · 文件网格 + 多选 + 打包（约 4 天）
- [ ] 网格布局、多选（⌘/Shift/⌘A/Esc）、批量操作条
- [ ] 打包 ZIP（`NSFileCoordinator` `.forUploading`）
- [ ] 双击打开、右键菜单、AirDrop 分享
- [ ] **验收**：拖入 6 个不同类型文件网格不挤压；多选 3 个打包成 zip 拖到桌面能正常解压

### M5 · 热区适配 + 多屏 + 打磨（约 1 周）
- [ ] `ScreenGeometry`：刘海探测，无刘海机器渲染虚拟黑条，两种情况面板外观完全一致
- [ ] 多屏跟随鼠标；监听 `didChangeScreenParametersNotification` 重建窗口
- [ ] Quick Look、深色/浅色、spring 动画、尊重 reduce motion
- [ ] i18n 收尾：全部字符串进 `.xcstrings`，补齐 en，**扫一遍确认没有硬编码中文**
- [ ] **验收**：外接屏上唤出正常；空格键预览；切英文界面无漏译；**冷启动到菜单栏图标 < 300ms**
- [ ] ⚡ 设计 App 图标（`Assets.xcassets`，1024×1024）

### M6 · 发布准备（约 3–5 天）
- [ ] 🔴 **生成 Sparkle EdDSA 密钥对，当天完成异地两份备份。** 用 `./bin/generate_keys` 生成，**私钥存进 macOS 登录钥匙串**（条目名 `Private key for signing Sparkle updates`），公钥填进 `Info.plist` 的 `SUPublicEDKey`。
      导出备份：`./bin/generate_keys -x <文件>`。查看：钥匙串访问.app 搜 `Sparkle`，或
      `security find-generic-password -s "https://sparkle-project.org" -a ed25519 -w`。
      **丢了就是死锁** —— 换新密钥要靠更新下发新公钥，而下发更新需要旧私钥签名。完整说明见签名手册第三章。
- [ ] Developer ID 签名 + notarize + DMG 打包脚本 `script/build_release.sh`
- [ ] 公证凭证：App-Specific Password 或 App Store Connect API Key，走 GitHub Secrets
- [ ] GitHub Actions：push tag → 构建 → 签名 → 公证 → DMG → 发 Release
- [ ] `appcast.xml` 生成脚本
- [ ] 录制演示 GIF → `docs/assets/demo.gif`（15 秒 / 10 MB 以内，README 两处占位在等它）
- [ ] `CONTRIBUTING.md`、`SECURITY.md`、`CODE_OF_CONDUCT.md`、Issue 模板（Bug / Feature）
- [ ] **验收**：在一台**没装过 Xcode 的干净 Mac** 上下载 DMG 双击能用，不报「已损坏」

---

## 阶段 3 · 自用两周

- [ ] 每天真实使用，记录所有卡顿和误操作
- [ ] 无崩溃满 14 天
- [ ] 复核[发布清单](docs/release-checklist.md)第六章的五条产品决定没有被「顺手优化」回去

> 这类工具的价值全在手感上。功能列表再长，唤出慢半拍就会被卸载。**这两周不要加新功能，只修手感。**

---

## 阶段 4 · 正式发布

- [ ] DMG 上传 COS `dl/Perch-1.0.0.dmg`，`appcast.xml` 上传 COS 根目录
- [ ] 记录 DMG 的 SHA-256 到腾讯云配置文档
- [ ] 无痕窗口点官网下载按钮，确认真的开始下载
- [ ] 官网下载区从「即将发布」换回真实链接，版本号与体积改成实际值
- [ ] 建 Homebrew tap 仓库 `KapiYue/homebrew-tap`，写 cask，实测 `brew install --cask perch`
- [ ] 走完[发布清单](docs/release-checklist.md)第二部分全部检查项
- [ ] GitHub Release 发布
- [ ] 发布后 24 小时内在 App 里实测一次 Sparkle 能检查到更新

---

## 阶段 5 · 发布之后再决定

这些**现在不要做**，做早了会污染判断。

- [ ] 变现方式（本期不做赞赏；一旦要收费，收款必须走站外平台，本站自建支付会触碰个人 ICP 备案的经营性红线）
- [ ] 是否换 GPL-3.0（想堵住被套壳卖钱就要换，且**贡献者进来之前换成本最低**）
- [ ] COS 自定义域名 `dl.perch.joy-coder.com`（默认域名首版够用）
- [ ] 是否新增 `/pricing`

---

## 关键路径

```
阶段 0（1 小时）
   ├─→ 阶段 1 官网上线 ────────────────────┐
   └─→ 阶段 2  M0 → M1 → M2 → M3 → M4 → M5 → M6 → 阶段 3 自用两周 ─→ 阶段 4 发布
                    ↑                                                    ↑
              生死线，卡住就停              官网下载链接在这里才换回真实地址
```

**总工期估算**：M0–M6 约 3.5 周纯开发，加自用两周，加官网上线（并行不占用），**到正式发布约 6 周**。

**唯一的高风险点是 M1 的 `NSFilePromiseProvider`。** 那一步通了，剩下的都是工作量问题。
