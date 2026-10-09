# iOS 首发：账号持有人操作清单

> 2026-09-28。流程与原理见 [ios-release.md](ios-release.md)；本文只列**必须由账号持有人亲手做**的事，
> 按顺序做完一项勾一项。打包在一台新的 Mac 上进行（第 1 步搭环境）。
> 凭证（.p8、.p12、密码）一律只放本机钥匙串 / `~/.appstoreconnect` / GitHub 仓库密钥，**不入库、不贴进聊天或 Issue**。

## 1. 新机器：搭打包环境

- [ ] macOS 26 或更新；App Store 装 **Xcode 26 或更新**（本项目要 iOS 26 SDK 与 Swift 6.2），
      首次打开 Xcode 装完组件后执行 `sudo xcodebuild -license accept`
- [ ] 装 Homebrew，再 `brew install xcodegen`（工程文件由 `apps/apple/project.yml` 生成，不入库）
- [ ] 拉代码：
      ```bash
      mkdir -p ~/workspace && cd ~/workspace
      git clone https://github.com/movieclaw/movieclaw.git && cd movieclaw
      ```
      已有仓库的机器改为 `git fetch origin && git checkout main && git pull --ff-only`，
      打包前 `git status` 干净、`git log -1 --oneline` 与 GitHub 上 main 最新提交一致（打的就是这个提交）
- [ ] 建本机签名配置（已被 .gitignore 忽略）：
      ```bash
      echo 'DEVELOPMENT_TEAM = <第 2 步确认的 Team ID>' > apps/apple/XcodeConfig/Signing.local.xcconfig
      ```
- [ ] Xcode 里建好 Apple Development 证书后，终端执行一次（会要 Mac 登录密码，输入时不回显）：
      `security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db`。
      不做的话打包时每个框架签名都弹一次钥匙串授权，几十个框叠在一起点不动
- [ ] 先编一次模拟器版确认环境：`apps/apple/scripts/build.sh`（`MC_SIM` 指定模拟器名，默认 iPhone 17；
      依赖包缓存在 `~/workspace/.mc-ios-spm`，首次要下载 FFmpeg 等二进制，几分钟）

## 2. 开发者账号（developer.apple.com）

- [ ] Membership 页确认**付费团队的 Team ID**，填进上面的 `Signing.local.xcconfig`，
      要确认它是付费团队而不是以前的个人免费团队
- [ ] Xcode → 设置 → 账户：登录这个 Apple ID（选下一步的 API 密钥也建议登录，真机调试要用）
- [ ] Identifiers：注册 App ID `io.movieclaw.app`（也可以留给 Xcode 首次导出时自动注册）

## 3. App Store Connect

- [ ] 用户和访问 → 集成 → App Store Connect API → 生成**团队密钥**，角色选**「管理」**（不能选「App 管理」：
      发布证书由 Apple 云端托管，「App 管理」密钥导出时报 `Cloud signing permission error`；
      Xcode 27 的 xcodebuild 又读不到 Xcode 里登录的账号（报 `No Accounts`），只能靠这把密钥）。
      下载 `.p8`（只能下载一次），放到 `~/.appstoreconnect/private_keys/AuthKey_<密钥 ID>.p8`，
      记下**密钥 ID** 与 **Issuer ID**。这把密钥同时用于 iOS 上传和 Mac 转码器公证
- [ ] App → 新建 App：平台 iOS、名称 MovieClaw（被占用就换）、主要语言简体中文、
      套装 ID `io.movieclaw.app`、SKU `movieclaw-ios`
- [ ] App 信息：
  - [ ] 隐私政策网址 `https://github.com/movieclaw/movieclaw/blob/main/docs/privacy-policy.md`
  - [ ] 技术支持网址 `https://github.com/movieclaw/movieclaw/issues`
  - [ ] 类别「娱乐」，价格免费
  - [ ] App 隐私问卷：**不收集数据**
  - [ ] 年龄分级问卷（「不受限制的网络访问」选是）
- [ ] TestFlight → 内部测试：新建内部测试组，把自己加进去；手机装 TestFlight App

## 4. 第一次上传（→ 内部 TestFlight）

- [ ] 先只导出不上传，验证签名：
      ```bash
      cd apps/apple
      export MC_ASC_KEY_ID=<密钥 ID> MC_ASC_ISSUER_ID=<Issuer ID>
      scripts/release.sh            # 成功会打印「已导出：build-release/…」
      ```
      首次会在账号下自动创建「Apple Distribution」证书与描述文件，属正常流程
- [ ] 上传：`scripts/release.sh --upload`
- [ ] 等 5～30 分钟，TestFlight 里出现构建后装到手机。注意：
  - TestFlight 版与开发调试版是**同一个套装 ID**，装上会替换手机上的调试版；签名团队不同，钥匙串里的登录
    令牌读不到，**首次打开要重新输一次服务器密码**
  - `-mc…` 调试开关（真机实验台、故障注入）只编进调试版，TestFlight 版里没有；之后要继续真机实验得重新装调试版
    （又会替换 TestFlight 版），见 [playback-qoe.md](playback-qoe.md) §10
- [ ] 首测要点（这一版播放器改动较多，见 playback-qoe.md §9）：
  - UHD 原盘续播能出画面（《黑豹2》从片中续播，修复前只有声音）
  - 4K60 片拖进度条 / 点 ±10 秒跟手（《抓特务》，修复前 1～2.5 秒）；落点会吸附到附近关键帧，偏差最多几秒
  - VC-1 原盘（《戴珍珠耳环》）续播位置正确、往前跳不卡住
  - 真实观看会在服务器留下播放质量记录（`mclaw` 或 `GET /api/v1/playback/stats/qoe` 查看），
    TestFlight 版开始积累的才是北极星「无打扰播放率」的真实数据
- [ ] **看 Apple 发来的邮件**：若有 ITMS-91053（隐私清单缺声明）或其他警告，把邮件原文发过来处理
- [ ] 打包产物在 `apps/apple/build-release/`（约 2 GB），确认没问题后可删

## 5. 对外测试 / 上架前（可以晚点做）

- [ ] **演示服务器**：`https://demo.movieclaw.io`，公网可达、HTTPS，不用自己的真实 NAS；只放开放授权
      影片，接好演示资源站与模拟下载器（`feat/demo` 分支 `demo/README.md`），每个功能都能端到端跑通
- [ ] **审核账号**：用部署环境里的审核账号（超管，不是登录页公布的公开只读账号），在 iPhone 上按
      `demo/README.md`「App Store 审核」的清单走一遍：
  - [ ] 能看片库、能播放
  - [ ] 搜索 → 站点资源 → 下载 → 活动页看进度 → 自动入库；订阅一部片直到收齐；刷流做种有数据
  - [ ] AI 助手接好真实模型，「我的 → 新会话」发一句能正常作答
  - [ ] 备注里写到的每一步都实际点一遍，报错或答非所问会按 2.1 拒审
- [ ] **审核期间停掉演示站的每日还原**，否则审核员的操作和接入的模型每天都会被清掉
- [ ] **测试信息**（TestFlight → 测试信息）：
  - Beta 版 App 描述、测试内容：写给测试者看，用中文（主要语言是简体中文，可另加英文本地化）
  - 反馈邮箱、隐私政策网址（见 §3）
  - 「Beta 版 App 审核信息」：联系人；勾「需要登录」填审核账号；备注用英文，模板见 ios-release.md §4
    ——**必须写明先点「连接服务器」填服务器地址**，否则审核员找不到账号密码输入框
  - Beta 版许可协议：留空（用 Apple 默认条款）
- [ ] **外部测试组**：TestFlight → 外部测试 → 新建组 → 加入构建（选 `APP_STORE_ELIGIBLE` 的新构建，
      不能是旧的仅限内部测试构建）→ 填「测试内容」→ 提交审核（一般 1 天内出结果，结果发邮件）
- [ ] **过审后开公开链接**：组内「测试员」旁「创建公开链接」，打开「限制测试员人数」先设个上限
      （如 50），链接发给朋友；测试者设备需 iOS 26 及以上
  - 同一营销版本号下之后上传的构建一般**免审**，加进组即自动推送；版本号递增后首个构建会再审一次
  - TestFlight 构建 90 天过期，至少每两三个月传一次新构建
- [ ] 6.9 英寸 iPhone 截图至少 3 张（用演示服务器内容截）——正式上架时才需要

## 6. Mac 转码器签名与公证（分支 feat/transcoder-notarize 合入 main 后生效）

- [ ] developer.apple.com → Certificates → 新建 **Developer ID Application**（只有账号持有人能建），
      在「钥匙串访问」里连私钥导出为 `.p12` 并设密码
- [ ] GitHub 仓库 → Settings → Secrets and variables → Actions，新增：
  - `MACOS_DEVELOPER_ID_P12`：`base64 -i developer-id.p12 | pbcopy` 的内容
  - `MACOS_DEVELOPER_ID_P12_PASSWORD`：导出时设的密码
  - `APPLE_API_KEY_P8`：第 3 步 `.p8` 文件的全文
  - `APPLE_API_KEY_ID` / `APPLE_API_ISSUER_ID`
- [ ] 下次发版后下载 `MovieClawTranscoder-macos-arm64.zip`，双击能直接打开即成功
      （本机手工打包的方法见 `macos/MovieClawTranscoder/README.md`）
