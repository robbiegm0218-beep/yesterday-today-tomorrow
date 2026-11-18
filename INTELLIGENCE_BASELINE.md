# 智能体验评估基线 v1

2026-11-05。INT-01首批基础设施，尚未完成端到端评分，不宣称已达到8分。

## 场景集

`Tests/PersonalAssistantTests/Fixtures/intelligence-baseline-v1.json`保存30个合成多轮场景，每个至少3步，覆盖：

- 对话接续：确认、取消、同名歧义、更名、换话题、重启。
- 执行恢复：完成/恢复、结果未知、目标消失、组织取消选择、隐藏与只读。
- 背景召回：同义词、跨天记忆、偏好纠正、来源冲突、覆盖不足、资料指令注入。
- 计划：无期限、已结束日程、局部调整、步骤/任务独立状态、跨日和昨日衔接。
- 跟进：有变化/无变化、解决不等于完成、额度/免打扰、来源失败、稍后与重启。

所有输入必须使用QA身份及合成事项，企业源使用受控替身。真实源写入仍须沿用原确认流程，不用正式资料填充这些测试。

运行`python3 scripts/intelligence-baseline.py`只校验场景集并汇总已有结果，不发模型请求，也不把“有30个用例”当成通过。当前`.build/intelligence-baseline-manifest.json`中30例均未完成端到端评分。

若记录实际结果，可用`--results <JSON文件>`汇总。每条必须含`case_id`、`outcome`（pass/fail/blocked）和`evidence`，不能重复ID；未运行项单独计数，不从通过率分母中隐去覆盖不足。质量评分字段保持null；正式打分还需按INTELLIGENCE_REVIEW.md中的维度，与用户认可的ChatGPT同题比较。

## 本机诊断

`chat-turn-diagnostics.json`保留最近100条主聊天运行记录：请求UUID、开始时间、总耗时、主请求耗时、模型标识、上下文字数、资料命中数、工具调用/有效提案数量、标准结果分类及服务端返回的token用量。

- 不保存问题、回复、工具参数、API Key或原始错误详情。错误仅映射到认证/权限、限流、网络、超时、响应格式等类别。
- `usageScope=primary_chat_only`：token只对应主聊天请求，不含后续自动记忆、后台计划及其他请求；用量缺失时为null，不冒充0。
- 字段按[DeepSeek官方Chat Completions文档](https://api-docs.deepseek.com/api/create-chat-completion/)的usage读取；可选统计损坏不会让正常回复变为失败。此版本不硬编码价格，也不输出未经核算的人民币费用。
- 诊断写入失败不会中断聊天，损坏诊断原文件保留；诊断不进入个人资料备份，恢复备份时不会伪造历史统计。
- 诊断只记录本轮生成提案时的状态；之后的确认/取消与实际结果仍以已保存操作卡片及源回执为准，不把提案数当执行成功数。

## build44的模型微验证

使用现有DeepSeek Key及独立无窗口入口，发送合成任务/状态，业务资料写入0。命令需显式设置`YUAN_RUN_DIALOGUE_ACCEPTANCE=1`并传`--verify-dialogue-context`，不自动在启动时运行。

`.build/build44-dialogue-live.log`：4/4通过，四次请求合计2759 token，耗时约2.69秒。检查已执行、待确认、已取消，以及当前源未完成状态优先于历史完成回执。只记录通过项、时间和用量，不记录凭据或回复全文。

这4条是回执理解的微验证，不能替代30个场景的完整执行，也不能换算成8分。

## build45查询循环诊断

主聊天更新为`usageScope=primary_chat_loop`，统计循环全部请求；新增modelRounds、readToolCallCount、stopReason。任一轮缺失/无效用量时整轮usage=null，自动记忆仍不计入。历史primary_chat_only记录保留原含义。

`.build/build45-dialogue-live.log`：5/5合成检查，5130 token，约4.86秒，含一条模型自行调用工具获取合成文档事实并返回来源；统计5个对话检查，查询检查可能包含多次HTTP请求，不是总请求次数。30例完整评分仍待执行。

## build46实时回查增量

`.build/build46-dialogue-live-final.log`：7项合成模型/保护检查和1项真实组织只读回查通过；7个模型对话检查累计10316 token，整体约9.71秒。成功场景检查实际后端调用及新状态；失败场景由程序直接停止，不将旧快照升级为最新事实。`stopReason=remote_read_failed`可用于诊断。真实事项不发送给模型、不打印ID/标题，业务写入0。早期未通过记录保留，微验证不替代30例完整评分或8分目标。

## build47：INT-04背景对照

新增`RecallEvaluationFixtures`的6组×5个参数变体（30组多轮背景样本），与原30个Agent目标场景分开登记。两侧均关闭工具、使用同一DeepSeek配置，仅更换初始背景，最终5/30→30/30；60次请求29625 token、55.17秒，业务写入0。新背景prompt token由12528增至16917，约增加35%，不声明更省token。详见[召回交付与方法边界](CONTEXT_RECALL.md)。

这批结果不填充原`intelligence-baseline-v1.json`的30个端到端结果，不替代ChatGPT同题参考、不同模型/推理策略对照或8分质量结论。生产诊断新增recallMilliseconds及recall统计对象，只保留计数/覆盖/歧义标记，仍不记录正文或Key。
