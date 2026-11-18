# 每日9点后台计划 / NEXT-08

> 当前状态（2026-10-29，build 25）：每日计划与主动提醒均启用。自然提醒、真实唤醒后的计划补跑已有证据；通知点击及原生系统权限关闭→恢复已联合验收通过。受控睡眠/退出与实机跨时区组合仍待补。下文保留各构建当时记录，以 [联合验收记录](JOINT_ACCEPTANCE.md) 和 [运行复验](RUNTIME_RECOVERY.md) 为准。


2026-10-28；0.2.0 build 23。开发完成、正式启用；真实机器睡眠/唤醒待验收。

## 使用

助手面板→定时任务→每日计划：开关、失败重试、最近尝试/成功、下一次检查目标和最近20条执行记录。工作台“后台计划建议”可展开查看用时、准备及依据。用户已有今日计划时不覆盖；没有计划时可核对调整后采用。系统通知保持关闭。

## 执行规则

- 使用包内LaunchAgent和SMAppService注册，实际注册后状态enabled；未注册时的notFound不再被当作永久阻塞。代码没有绕过系统后台许可。
- 每日本机时间9点、加载服务时及每5分钟启动无窗口worker；启动后先检查开关、时间、日期/时区及结果，成功当天不再发起网络生成。前台也每30秒补充检查，不能仅依赖应用保持打开。
- 后台和前台共享操作系统文件锁，覆盖网络生成及结果提交；进程退出释放锁。历史running在重新获得锁后标记中断，避免永久卡住。
- 自动失败当天最多尝试3次，第一次失败等5分钟、第二次等15分钟，第三次后等次日或用户手动重试。成功后手动重试也不能重复生成同日结果。
- 结束时重新检查日期/时区、开关及结果形状。关闭期间返回的结果丢弃并记取消；不能提交前一天的晚到结果。
- 只读取已选择组织、未隐藏事项及本机未完成待办和项目。损坏的本机文件不伪装成空数据成功；Key不可读取时失败记录并重试，不弹出认证窗口。
- 后台DWS子进程补齐CLI所在目录、常见Node安装目录及系统PATH，兼容launchd的精简环境。
- 生成结果、状态和配置独立于原数据。备份包含状态/建议，但恢复备份不开启服务；清除/恢复前与后台执行锁互斥。
- 自动运行只产生建议，不创建源待办/日程、不会覆盖执行勾选，也不会发送通知。没有可安排事项时记录空结果成功。

## 验收证据

- `.build/background-plan-tests.log`：90项注册检查，2项真实账号用例跳过，其余通过。含操作系统锁并发、9点前不执行、同日不重复、失败退避/封顶/手动恢复、关闭期间丢弃、中断恢复、损坏状态保护、过期结果拒绝、跨日/时区及备份恢复。
- 正式首次补跑实际生成成功，运行记录1条，下一目标2026-10-29 09:00。初次生成由前台补跑完成，不能伪称由系统定时完成。
- `.build/background-independent-generator.log`：独立无窗口签名进程读取原Key和真实来源，实际模型生成通过；此探针不提交结果、不修改个人数据。
- `.build/background-personal-integrity.json`：聊天、记忆、待办、项目、已保存计划5文件哈希不变。
- `.build/background-qa-schedule.json` / `.build/background-qa-register.log`：独立签名QA服务注册为enabled，近时StartCalendarInterval到点触发，注册进程此前已退出。QA只生成合成结果，不读取正式资料。
- `.build/background-qa-system-evidence.json`：真实系统执行1次、退出码0，正式应用未运行。`.build/background-qa-result.json`：成功、触发来源launchd、结果合成3项通过。
- 重复kickstart该QA服务，仍只有1条成功记录；`.build/background-qa-unregister.log`：测试服务已注销，不留额外自启动任务。
- `.build/background-production-worker-result.json`：主应用退出后，实际注册的正式worker能启动并正常退出，同日记录字节保持不变。
- 隔离原生GUI已验证：系统生成的建议→核对调整页→确认保存→退出重启恢复；后台建议和执行计划分别保留，已有计划后不再显示采用按钮。
- `.build/background-plan-status.png`：正式状态页；本期不申请通知权限。签名Release构建日志 `.build/background-plan-build.log`。

## 待验收与实际限制

- 用户已选择暂不进行真实Mac睡眠/唤醒，本项保持待验收。不是代码故障，也不能写为通过。
- 未等待下一个自然日9点。时区/跨日/夏令时规则使用自动化，实际系统定时触发用隔离近时日历触发验证。
- 睡眠/关机/注销期间进程不会执行；恢复后只补当天，前几天计划不追溯生成。具体执行可因系统唤醒、后台许可、网络及5分钟补充检查延后。
- 下一阶段NEXT-09通知仍未启用。后台结果中来源可能已变化，采用时会按最新事项校验。

系统机制依据：[Apple ServiceManagement](https://developer.apple.com/documentation/servicemanagement/smappservice)、[Apple定时任务说明](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/ScheduledJobs.html)。实际支持范围以上述本机验收为准。


后续更新：NEXT-09已于build 24单独交付并获用户确认启用，主动提醒使用同一后台服务；本文件中的通知关闭状态为build 23验收当时状态。见 [ACTIVE_REMINDERS.md](ACTIVE_REMINDERS.md)。


2026-10-29复验更新：已观察真实睡眠后的当天计划补跑及自然20:15时段提醒提交/系统记录，部分来源故障恢复已在build 25修复；细节和仍未覆盖组合见 [RUNTIME_RECOVERY.md](RUNTIME_RECOVERY.md)。此前待验收文字保留为当时记录。

## build41：无窗口任务入口（2026-11-04）

正式`--daily-plan-worker`不再通过SwiftUI Color.clear View启动；由进程入口直接运行NSApplication事件循环和后台任务，没有Scene/Window。主包通知身份、UserDefaults及数据目录保持，计划生成/不重复/提醒检查策略沿用。前台开启状态3轮系统触发、隔离生成及不重复触发均验证零窗口。详见[RUNTIME_RECOVERY.md](RUNTIME_RECOVERY.md)。
