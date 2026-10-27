# 昨天今天明天 · 稳定签名配置

## 当前状态（2026-10-27）

已配置本机 Apple Development 签名身份（公开指纹保存在被 Git 忽略的 `Resources/Signing.local.json`），证书有效期至 2027-10-27。此前身份无效的原因为缺少 WWDR G3 中间证书；从 Apple 官方下载、验证并补入登录钥匙串后，系统识别为有效身份。未覆盖系统信任设置。

应用“昨天今天明天”已完成证书签名，Apple Development → WWDR → Apple Root CA 证书链及签名完整性检查通过。原有 DeepSeek Key 已在应用内授权后读取，真实连接成功；退出后冷启动可自动读取，无需再次授权。同证书更新检查记录见开发计划 KEY-02。

私钥和 API Key 均留在本机钥匙串。本地开发签名不等同于 Developer ID 公开分发与公证，后者仍未配置。

## 已有另一台 Mac 的签名身份

在原 Mac 的“钥匙串访问 → 登录 → 我的证书”中，签名证书下应能展开对应私钥。将该证书和私钥导出为加密 `.p12`，通过你自己的安全方式放到这台 Mac；在本机双击导入，在系统窗口输入导出密码。不要把文件、私钥或密码发到聊天。

仅下载 `.cer` 通常不能代替对应私钥；导入后由本机检查是否形成可用签名身份，不撤销现有证书。

## 普通 Apple 账号，尚无本机证书

1. 从 Mac App Store 安装 Apple 官方 Xcode。
2. 打开 Xcode → Settings → Apple Accounts（旧版为 Accounts），自行登录普通 Apple 账号并完成双重认证；免费账号对应 Personal Team。
3. 选择对应 Team → Manage Certificates → `+` → Apple Development，为这台 Mac 创建本地开发签名身份。
4. 完成后只告诉我“证书已在本机配置”，由我检测可用身份并将其固定到构建配置。

当前只解决本机开发版本的稳定签名，不要求先做公开分发或公证。后续公开分发再配置 Developer ID Application。

## 构建配置与最终核对

- 私钥保留在本机钥匙串。
- `Resources/Signing.local.json` 仅保存签名身份的公开 SHA-1 指纹，并已加入 `.gitignore`。
- `scripts/build-app.sh` 优先使用显式 `YUAN_CODE_SIGN_IDENTITY`，否则读取该本地配置。配置无效或证书不可用时停止构建，不回退临时签名。
- 构建前必须退出应用；应用先在暂存目录完整构建、签名与校验，再安装。
- 最终稳定签名版本可能需要一次授权旧条目；操作发生前会说明。应在系统窗口完成，不向聊天提供密码。
- 完成标准：读到原有 Key、真实模型请求成功、冷启动不弹框且可读取、同证书重新构建后继续可读取；不能只以“不弹框”判定修复完成。

## Apple 官方说明

- [创建、导出和删除签名证书](https://help.apple.com/xcode/mac/current/en.lproj/dev154b28f09.html)
- [查看钥匙串中的签名证书及私钥](https://help.apple.com/xcode/mac/current/en.lproj/dev97211aeac.html)
- [Xcode 签名身份同步与管理](https://developer.apple.com/documentation/xcode/sharing-your-teams-signing-certificates)
- [已经信任的应用再次请求钥匙串访问](https://support.apple.com/guide/keychain-access/kyca1331/mac)

普通账号流程依据：[Apple 个人团队说明](https://developer.apple.com/help/account/basics/about-your-developer-account/)。免费团队存在能力及配置期限限制；不先承诺永久免授权，以本应用实际证书签名、冷启动及更新读取结果为准。
