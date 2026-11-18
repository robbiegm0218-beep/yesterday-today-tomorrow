#!/usr/bin/env python3
"""Run the original 30 scenarios in separate app processes and retain evidence.
Uses the existing signed app and saved credential; no credentials in arguments/logs.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--only', nargs='*')
    parser.add_argument('--experience', action='store_true', help='Run two controlled delayed-memory integration cases instead of the original corpus')
    parser.add_argument('--streaming', action='store_true', help='Run two real streaming cancellation/proposal cases')
    parser.add_argument('--goals', action='store_true', help='Run durable pause/restart/replay/scope cases')
    parser.add_argument('--research', action='store_true', help='Run five bounded remote message/document evidence cases')
    parser.add_argument('--followups', action='store_true', help='Run seven live-model bounded followup evidence cases')
    parser.add_argument('--stages', action='store_true', help='Run five confirmed staged-goal and restart cases')
    parser.add_argument('--stage-input', action='store_true', help='Run eight structured stage question and natural reply cases')
    parser.add_argument("--stage-revision",action="store_true",help="Run eight stage revision and field correction scenarios")
    parser.add_argument("--stage-facts",action="store_true",help="Run eight typed stage fact verification scenarios")
    parser.add_argument("--timeouts",action="store_true",help="Run four saved-key streaming connection and timeout retry cases")
    parser.add_argument("--next-steps",action="store_true",help="Run eight fact gap next-step and actual restart cases")
    parser.add_argument("--created-receipts",action="store_true",help="Run four offline production create receipt cases; no model API or credential lookup")
    parser.add_argument("--stage-references",action="store_true",help="Run four offline cross-stage reference cases with intercepted model responses")
    parser.add_argument("--stage-composites",action="store_true",help="Run four offline composite fact condition cases with local fixture responses")
    parser.add_argument("--remote-facts",action="store_true",help="Run four offline remote fact and cross-source cases using synthetic DWS detail responses")
    parser.add_argument("--continuity",action="store_true",help="Run four offline conversation focus/numbered choice scenarios with intercepted responses")
    parser.add_argument("--correction",action="store_true",help="Run four offline focus correction and local status qualifier cases")
    parser.add_argument("--preferences",action="store_true",help="Four offline saved preference continuation scenarios")
    parser.add_argument("--preference-probes",action="store_true",help="Two targeted live model response probes with synthetic preferences only")
    parser.add_argument("--semantic",action="store_true",help="Four offline semantic reference tool scenarios")
    parser.add_argument("--semantic-probes",action="store_true",help="Two bounded live semantic reference interpretation probes")
    parser.add_argument("--todo-cards",action="store_true",help="Four offline completion card regression cases")
    parser.add_argument("--todo-card-probe",action="store_true",help="One live synthetic full-app missing-card reproduction")
    parser.add_argument("--stage-alternative",action="store_true",help="Four offline same-goal semantic stage revision scenarios")
    parser.add_argument("--stage-alternative-probe",action="store_true",help="One live synthetic same-stage alternative preview")
    parser.add_argument("--reference-question",action="store_true",help="Four offline combined reference/question cases")
    parser.add_argument("--reference-question-probe",action="store_true",help="One live synthetic reference/question app flow")
    parser.add_argument("--reference-exclusion",action="store_true",help="Four offline original-list exclusion and correction cases")
    parser.add_argument("--reference-exclusion-probe",action="store_true",help="One live synthetic literal correction answer")
    parser.add_argument("--task-preferences", action="store_true", help="Offline task preference lifecycle and process restart")
    parser.add_argument("--composer-performance", action="store_true", help="Offline hidden-host composer invalidation and update timing")
    parser.add_argument("--input-budget", action="store_true", help="Offline primary context audit, preflight rejection and explicit recovery")
    parser.add_argument("--context-selection", action="store_true", help="Offline social background selection and protected full-context fallback")
    args = parser.parse_args()
    assert sum([args.context_selection,args.input_budget,args.composer_performance,args.task_preferences,args.experience,args.streaming,args.goals,args.research,args.followups,args.stages,args.stage_input,args.stage_revision,args.stage_facts,args.timeouts,args.next_steps,args.created_receipts,args.stage_references,args.stage_composites,args.remote_facts,args.continuity,args.correction,args.preferences,args.preference_probes,args.semantic,args.semantic_probes,args.todo_cards,args.todo_card_probe,args.stage_alternative,args.stage_alternative_probe,args.reference_question,args.reference_question_probe,args.reference_exclusion,args.reference_exclusion_probe]) <= 1
    corpus = json.loads((ROOT/'Tests/PersonalAssistantTests/Fixtures/intelligence-baseline-v1.json').read_text())
    cases = corpus['cases']
    if args.context_selection:
        cases = [{"id":"INT-152","turns":["social greeting", "business question", "mixed greeting and business", "ordinary recalled knowledge", "explicit general concept", "contradictory personal question"],"expected":["separate recall modules; explicit general mode has no private data/tools/citations; protected business fallback"]}]
    if args.input_budget:
        cases = [{"id":"INT-151", "turns":["normal request", "oversized input", "explicit fresh request"], "expected":["module audit, no dispatch on overflow, original records and recovery"]}]
    if args.composer_performance:
        cases = [{"id":"INT-150","turns":["225/500 synthetic history", "programmatic draft updates", "send/cancel"], "expected":["no global model publication during nonempty typing; record actual history layout"]}]
    if args.task_preferences:
        cases = [{'id':'INT-149','turns':['task preference','restart','continue and expire'], 'expected':['task scoped only; no extraction or writes']}]
    if args.experience:
        cases = [{'id': 'INT-31', 'turns': ['记住下午专注偏好', '记忆提取挂起时继续只读聊天', '释放提取并核对原话来源'], 'expected': ['回复先释放发送状态，第二次聊天正常，记忆按原消息保存一次']},
                 {'id': 'INT-32', 'turns': ['记住下午专注偏好', '提取挂起时关闭自动记忆', '释放迟到结果'], 'expected': ['关闭后迟到结果不写回']} ]
    if args.streaming:
        cases = [{'id':'INT-33','turns':['流式首段','主动停止后马上发送新消息','核对迟到与片段持久化'], 'expected':['首段先显示、停止清预览、新消息不被旧请求覆盖']},
                 {'id':'INT-34','turns':['流式创建提案','核对完整卡片与预览隐藏','取消'], 'expected':['完整工具校验与确认边界保留，参数片段不展示或执行']}]
    if args.goals:
        cases = [{'id':'INT-35','turns':['流式中暂停并保存目标','修改源事项后实际进程退出','恢复原目标并读取新事实'], 'expected':['目标ID和预算保留，重新核对当前事实，不执行写入']},
                 {'id':'INT-36','turns':['确认创建任务','实际进程退出','继续原目标'], 'expected':['已确认创建不重放，回执与预算保留']},
                 {'id':'INT-37','turns':['暂停目标','取消原组织选择','尝试继续'], 'expected':['范围变化时不发送新模型请求或写入']},
                 {'id':'INT-38','turns':['写请求未产生卡片时暂停','实际退出进程','恢复并核对待确认卡片'], 'expected':['沿用目标与预算，显式写意图仍需产生卡片，确认前不写入']},
                 {'id':'INT-39','turns':['计划编辑器已提交但尚未更新聊天回执','实际退出进程','先阻止继续再由原卡片核验'], 'expected':['写入前持久化未知标记，按原actionID核验，不重复保存版本']}]
    if args.research:
        cases = [{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (40,'查最近消息','真实工具命中与出处，读取不写入'),
            (41,'查文档并读正文','标题不冒充正文，忽略资料中的越权指令'),
            (42,'部分覆盖零命中','不宣称文档不存在'),
            (43,'查询失败后停止提案','未知状态不基于旧快照写入'),
            (44,'多篇文档候选','不默认读第一篇正文')]]
    if args.followups:
        cases = [{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (45,'新消息核对已有跟进','新候选归属待核对，不执行资料中的指令'),
            (46,'旧消息命中','不冒充新进展'),
            (47,'基线早于七天覆盖','未命中仍未知'),
            (48,'远端失败','停止提案，跟进/源事项不变'),
            (49,'近期更新文档的片段','读取正文，不将文档修改时间等同段落新增'),
            (50,'多个待跟进事项','先澄清，不能默认第一项'),
            (51,'已确认关联的精确消息','区分已关联依据与候选，不自动解决跟进')]]
    if args.stages:
        cases = [{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (52,'拟定并采用两个阶段，先读后确认写，逐阶段人工核对','依赖、条件、回执和预算均保留，不自动推进'),
            (53,'阶段中暂停，源标题更新后实际进程退出与继续','同一父/子目标及原预算，重查新事实'),
            (54,'采用后取消组织选择再启动阶段','范围变化不发新模型请求'),
            (55,'写卡片尚未确认时结束父目标','子阶段及旧卡片都不能继续写入'),
            (56,'取消阶段方案后实际退出重启','取消保留，无阶段启动或写入')]]
    if args.stage_input:
        cases = [{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (57,'阶段缺标题，直接补充后生成原确认卡片','同一父/子目标、预算不重置，不重述原目标，确认前不创建'),
            (58,'同名事项提问后自然回复第二个','绑定精确ID并读取对应负责人，不默认首项'),
            (59,'等待补充时实际退出重启','原问题保留，补充后沿同一阶段继续'),
            (60,'等待补充时明确换话题','不挪用旧阶段，新话题正常回答'),
            (61,'范围变化后提交补充','不发模型请求，原问题和草稿保留'),
            (62,'明确更改阶段目标','不当作背景执行旧指令'),
            (63,'问题卡片已有聊天草稿','不覆盖草稿或发请求'),
            (64,'过期提问卡片','不提交到新问题、不写入')]]
    if args.stage_revision:
        cases = [{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (65,'自然纠正阶段标题打开预览并取消','无模型请求，原问题和草稿保留'),
            (66,'待确认卡片前修订待办标题','旧卡片失效，同一预算手动继续，仅确认新标题'),
            (67,'修订后实际退出重启','修订和旧卡片取消保留，同一子目标继续'),
            (68,'已写入或已完成的阶段尝试修订','不覆盖已执行结果，不产生新请求'),
            (69,'前置已核对后修订尚未启动的后续阶段','已完成依赖保留，无新子运行'),
            (70,'范围变化与失效修改预览','保存拒绝，不覆盖方案或发模型请求'),
            (71,'将未执行写入阶段明确改为只读','旧问题失效，只读核对新内容，不生成写卡片'),
            (72,'修订条件后重新生成同类操作卡片','旧卡片不能执行，原预算下新卡片仍需确认且仅写一次')]]
    if args.stage_facts:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (73,'模型文字不能替代未满足事实','当前未完成阻止阶段完成并说明缺口'),
            (74,'当前字段满足后人工确认','精确ID复核满足后仅人工完成阶段，不改业务或启动后续'),
            (75,'目标消失但有同名已完成项','未知，不默认同名项'),
            (76,'满足快照后当前文件损坏','未知，不用恢复副本冒充最新记录'),
            (77,'满足快照后源变化并实际重启','保留历史结果，确认前重读并阻止过时完成'),
            (78,'范围变化后复核','不读写结论、不调用模型'),
            (79,'同ID标题已改变','报告标题缺口，保留精确归属'),
            (80,'继续原阶段使用最新复核结果','同一子运行和预算，当前已完成，不自动推进')]]
    if args.timeouts:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (81,'既有Key最小流式连通测试','不发送真实资料，完整响应且无业务操作'),
            (82,'合成较长背景流式连通测试','较长上下文仍取得完整响应'),
            (83,'受控预算耗尽后明确新请求','旧运行不重置，新运行完整响应，无回执不重放写入'),
            (84,'预算耗尽重试遇到聊天草稿','不覆盖草稿、不发新请求')]]
    if args.next_steps:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (85,'只读事实未满足','建议明确修订，打开预览并取消，无模型和写入'),
            (86,'当前源不可读','只复核一次，无进展停止；新事实可恢复人工核对'),
            (87,'原精确目标消失并实际重启','只追问一次，补充沿用原预算，仍未知则明确修订'),
            (88,'点击前事实已变化','旧建议失效，刷新后等待用户核对'),
            (89,'明确修订为精确目标完成操作','同一预算生成卡片，确认后查新事实，再人工完成阶段'),
            (90,'范围改变或有独立草稿','不执行旧建议，不覆盖草稿或请求模型'),
            (91,'取消精确目标操作卡片','停止而非自动再次提交'),
            (92,'无进展停止后实际重启','停止与尝试次数保留，不重置预算或建立新目标')]]
    if args.created_receipts:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (93,'确认创建、同名记录与人工阶段核对','绑定原创建精确ID，不自动完成业务或下一阶段'),
            (94,'创建后实际进程退出并替换源ID','绑定和预算保留，不改绑同名/同操作记录，不重复创建'),
            (95,'本地已写入但聊天未确认的中断边界','核对原sourceActionID，回执补齐且仅创建一次'),
            (96,'创建结果已定位后当前源损坏','当前未知阻止阶段完成，不用备份；原源恢复后仍绑定原ID')]]
    if args.stage_references:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (97,'一句话打开引用预览、取消、明确采用和只读启动','唯一原创建ID写入请求，保留同一父目标和确认边界'),
            (98,'引用采用后实际进程退出，原记录更名后再启动','引用保留，读取原ID最新标题，不用旧回复替代'),
            (99,'启动前原ID消失，出现同名同操作标记的另一项','在请求凭据和新子目标前阻止，不改绑不重建'),
            (100,'前阶段创建了多条同名事项','一句话不默认选择，草稿保留，可明确选择第二张原卡片')]]
    if args.stage_composites:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (101,'明确增加多项条件并沿同一阶段读取','部分满足不算完成，全部满足后仍需人工确认'),
            (102,'次要目标消失、有限复核后实际退出重启','未知不被已知未满足项遮盖，无进展停止与预算保留'),
            (103,'当前文件损坏和点击前事实变化','不用备份冒充，过期调整不执行，读取新快照'),
            (104,'重复目标、范围变化和过期修改预览','不丢弃空项或默认目标，不重置原预算')]]
    if args.remote_facts:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (105,'精确远端与本地条件全部满足后人工确认','原组织实时读取，局部满足不能完成，不调用模型'),
            (106,'查询中改变范围、恢复后实际退出重启','迟到丢弃，重启后重新读取失败即未知，不沿用旧满足'),
            (107,'取消读取、耗尽原读取预算和结束目标','不接受取消结果，不增加第七次读取或重置预算'),
            (108,'错误组织预览、错ID响应、隐藏范围改变','不跨组织或默认同名，旧远端满足不能绕过新鲜核对')]]
    if args.continuity:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (109,'连续多轮回指同一事项','每轮重读当前事实，不要求重述名称'),
            (110,'同名事项选择第二个并实际退出重启','保存原展示顺序和精确ID，不按新列表顺序选项'),
            (111,'来源范围改变后回答编号','不沿用旧焦点，不发送模型请求'),
            (112,'编号越界与换话题后再选择','不猜测，不从模型文字解析可执行事项')]]
    if args.correction:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (113,'选定后实际退出再纠正为第一个','沿原列表纠错，不调用模型或记忆提取，不重放旧操作'),
            (114,'用已加载本地完成状态选择原候选','符合状态的唯一项可定位，改选不写源'),
            (115,'多个另一个重新澄清','不猜测，按新显示列表选择'),
            (116,'唯一另一个及原替代项消失','本地改选，旧ID缺失时旧编号作废')]]
    if args.preferences:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (117,'按相关已确认偏好承接讨论','来源明确，纯承接无写工具/自动记忆'),
            (118,'默认偏好冲突与本轮临时要求','先澄清，临时要求不改长期设置'),
            (119,'临时详细后实际退出，按旧偏好继续','原简短偏好保持，临时要求不变长期'),
            (120,'原话参考与删除偏好','不启用写工具，不从旧对话补造已删记忆')]]
    if args.preference_probes:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':['合成偏好与主题，单轮只读模型回答；人工检查输出，不计8分评估']} for i,label in [(121,'已确认简短偏好承接'),(122,'本轮临时详细覆盖默认简短')]]
    if args.semantic:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (123,'两个筛选顺序歧义与实际重启','本地澄清，重启选择原ID不重放操作'),
            (124,'明确状态筛选后第二个','按原列表核对并保存只读焦点'),
            (125,'另一个叠加状态及原ID失效','不包含当前焦点，不滑位改绑'),
            (126,'绕过指代读取的写提案与范围竞态','未明确目标不出卡片，迟到结果作废')]]
    if args.semantic_probes:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':['单轮模型解释与本地读取；合成原列表；无写入，不计8分评分']} for i,label in [(127,'未说明位置与状态顺序时澄清'),(128,'明确未完成子集中的第二项')]]
    if args.todo_cards:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':[expect]} for i,label,expect in [
            (129,'旧多轮确认但无卡片，查找后生成，实际退出再同意','真实pendingActions、原ID绑定，不重复或自动执行'),
            (130,'明确目标直接生成两个独立卡片','零模型调用，口头同意不是按钮确认'),
            (131,'同名/部分名称歧义选择与原ID删除','先明确目标，再生成卡片，不按同名新ID改绑'),
            (132,'取消后口头同意与来源改变','不恢复取消卡片，不借旧请求绕过范围')]]
    if args.todo_card_probe:
        cases=[{'id':'INT-133','turns':['合成复现原多轮无卡片对话并真实查找'],'expected':['完整应用生成真正待确认完成卡，单次模型查找，未确认不改源']}]
    if args.stage_alternative:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':['original goal/criteria/dependencies/budget retained;preview only,manual confirmation']} for i,label in [(134,'generate,exit,reopen and confirm bound preview'),(135,'close/reopen/dismiss/restart'),(136,'protected criteria/scope/unknown receipt guards'),(137,'cancel late result and exhausted original budget')]]
    if args.stage_alternative_probe:
        cases=[{'id':'INT-138','turns':['one live synthetic current-stage alternative'],'expected':['one actual bound preview,no source writes,original budget']}]
    if args.reference_question:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':['exact focus then read-only answer;original question retained;no writes']} for i,label in [(139,'qualified reference and owner/deadline answer'),(140,'ambiguous reference,restart,choose and answer same question'),(141,'unknown fields and mixed write proposal rejection'),(142,'scope changes and missing original ID')]]
    if args.reference_question_probe:
        cases=[{'id':'INT-143','turns':['one live synthetic reference plus follow-up question'],'expected':['two bounded requests,one bound local read,no source writes']}]
    if args.reference_exclusion:
        cases=[{'id':'INT-'+str(i),'turns':[label],'expected':['original IDs,local literal correction/exclusion,read-only answer,scope and budget guards']} for i,label in [(144,'not second but third plus owner/deadline'),(145,'exclude two original positions,clarify,restart and answer'),(146,'contradiction/invalid ordinal/ambiguous state/mixed mutation and focus-only'),(147,'scope/deleted ID/new explicit name precedence')]]
    if args.reference_exclusion_probe:
        cases=[{'id':'INT-148','turns':['one saved-key synthetic literal correction answer'],'expected':['one answer request,no interpretation model or business writes']}]
    known = {c['id'] for c in cases}
    assert not args.only or set(args.only) <= known
    if args.only: cases = [c for c in cases if c['id'] in args.only]
    app = args.app.resolve(); executable = app/'Contents/MacOS/PersonalAssistant'
    binary_hash = hashlib.sha256(executable.read_bytes()).hexdigest()
    out = args.output.resolve(); out.mkdir(parents=True, exist_ok=True)
    assert not (out/'results.json').exists(), 'Use a fresh output directory; prior runs are evidence.'
    env = dict(os.environ, YUAN_RUN_AGENT_ACCEPTANCE='1')
    rows = []; started = time.monotonic(); tokens = 0
    for case in cases:
        case_id = case['id']; log = out/(case_id+'.log'); case_started = time.monotonic()
        if time.monotonic()-started > 900 or tokens > 1500000:
            record = {'case_id':case_id,'outcome':'blocked','failure':'evaluation_budget','evidence':str(log)}
            log.write_text('Not executed: evaluation budget exceeded.\n')
        else:
            try:
                command = [str(executable),'--verify-agent-scenario','--scenario-id='+case_id]
                if args.context_selection: command.append("--offline-context-selection")
                if args.input_budget: command.append("--offline-input-budget")
                if args.composer_performance: command.append("--offline-composer-performance")
                if args.task_preferences: command.append("--offline-task-preferences")
                if args.created_receipts: command.append('--offline-receipts')
                if args.stage_references: command.append('--offline-references')
                if args.stage_composites: command.append('--offline-composites')
                if args.remote_facts: command.append('--offline-remote-facts')
                if args.continuity: command.append('--offline-continuity')
                if args.correction: command.append('--offline-correction')
                if args.preferences: command.append('--offline-preferences')
                if args.preference_probes: command.append('--live-preference-probe')
                if args.semantic: command.append('--offline-semantic')
                if args.semantic_probes: command.append('--live-semantic-probe')
                if args.todo_cards: command.append('--offline-todo-cards')
                if args.todo_card_probe: command.append('--live-card-probe')
                if args.stage_alternative: command.append('--offline-stage-alternative')
                if args.stage_alternative_probe: command.append('--live-stage-alternative')
                if args.reference_question: command.append('--offline-reference-question')
                if args.reference_question_probe: command.append('--live-reference-question')
                if args.reference_exclusion: command.append('--offline-reference-exclusion')
                if args.reference_exclusion_probe: command.append('--live-reference-exclusion')
                phases = []; outputs = []
                for phase in range(2):
                    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=105)
                    outputs.append(result.stdout+'\n'+result.stderr)
                    log.write_text('\n'.join(outputs))
                    reports = [json.loads(s[len('AGENT_SCENARIO_RESULT: '):]) for s in result.stdout.splitlines() if s.startswith('AGENT_SCENARIO_RESULT: ')]
                    if not reports: raise RuntimeError('missing_scenario_report')
                    record = reports[-1]; phases.append(record)
                    if record['outcome'] != 'restart_required': break
                    assert phase == 0 and case_id in ('INT-06','INT-07','INT-30','INT-35','INT-36','INT-38','INT-39','INT-53','INT-56','INT-59','INT-67','INT-77','INT-87','INT-92','INT-94','INT-98','INT-102','INT-106','INT-110','INT-113','INT-119','INT-123','INT-129','INT-134','INT-140','INT-145','INT-149')
                    command.append('--resume-sandbox='+record['sandboxPath'])
                if record['outcome'] == 'restart_required': raise RuntimeError('restart_incomplete')
                record = dict(record)
                for field in ['tokens','modelRequests','automaticBusinessWrites','simulatedModelRequests','externalModelRequests','controlledRemoteReads','realRemoteReads']:
                    record[field] = sum(p.get(field,0) for p in phases)
                record['inProcessSeconds'] = sum(p.get('elapsedSeconds',0) for p in phases)
                record['usageComplete'] = all(p.get('usageComplete',False) for p in phases)
                record['processIDs'] = [p.get('processID') for p in phases]
                record['processRestartCount'] = len(phases)-1
                if len(phases)>1: assert len(set(record['processIDs'])) == 2
                assert record['case_id'] == case_id
                sandbox = Path(record['sandboxPath']).resolve()
                assert sandbox.name.startswith('yuan-agent-e2e-') and sandbox.is_dir()
                evidence_dir = out/case_id
                shutil.copytree(sandbox,evidence_dir)
                record['evidence'] = str(evidence_dir)
                record['originalTurns'] = case['turns']; record['expectedCriteria'] = case['expected']
                if result.returncode != 0:
                    record['outcome'] = 'fail'; record['failure'] = 'process_exit_'+str(result.returncode)
                tokens += record.get('tokens',0)
            except subprocess.TimeoutExpired as error:
                log.write_text((error.stdout or b'').decode(errors='replace') if isinstance(error.stdout,bytes) else (error.stdout or ''))
                record = {'case_id':case_id,'outcome':'blocked','failure':'process_timeout','evidence':str(log)}
            except Exception as error:
                record = {'case_id':case_id,'outcome':'blocked','failure':type(error).__name__,'evidence':str(log)}
        record['elapsedSeconds'] = time.monotonic() - case_started
        record['binarySha256'] = binary_hash
        rows.append(record)
        (out/'results.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2))
        failures = [k for k,v in record.get('checks',{}).items() if not v]
        print(case_id, record['outcome'], record.get('failure','none'), ','.join(failures), flush=True)
    summary = {'requested':len(cases),'completed':len(rows),'outcomes':{s:sum(r['outcome']==s for r in rows) for s in ['pass','fail','blocked']},
               'tokens':tokens,'allUsageMeasured':all(r.get('usageComplete',False) for r in rows),
               'modelRequests':sum(r.get('modelRequests',0) for r in rows),'elapsedSeconds':time.monotonic()-started,
               'automaticBusinessWrites':sum(r.get('automaticBusinessWrites',0) for r in rows),'binarySha256':binary_hash,
               'qualityScore':None,'humanReviewRequired':True,'scope':('offline recall modules and explicit general concept/social selection; synthetic only' if args.context_selection else 'offline primary input audit and budget; synthetic only; no model API' if args.input_budget else 'hidden-host synthetic updates;not keyboard/IME latency' if args.composer_performance else 'offline task preference lifecycle; synthetic; real restart; no model API' if args.task_preferences else 'literal original-list correction/exclusion and read-only question,synthetic facts,same-budget restart145' if args.reference_exclusion or args.reference_exclusion_probe else 'same-sentence reference and read-only question,synthetic facts,same-budget restart140' if args.reference_question or args.reference_question_probe else 'same-stage alternative preview;synthetic only;original budget;actual restart134' if args.stage_alternative or args.stage_alternative_probe else 'one full app live missing-card reproduction,synthetic tasks/history,no source write' if args.todo_card_probe else 'offline completion card regression,lookup/binding/real restart129' if args.todo_cards else 'two bounded live semantic tool probes,synthetic choices,no business tools' if args.semantic_probes else 'offline semantic reference tool,original-list validation,actual restart123' if args.semantic else 'two bounded saved-key live probes,synthetic preferences/topic,no business tools' if args.preference_probes else 'offline preference continuation,intercepted streams,actual restart119,no external API' if args.preferences else 'offline explicit focus correction and loaded local completion qualifiers; intercepted responses; actual restart113; no external API' if args.correction else 'offline conversation continuity; intercepted responses; actual restart110; no external API' if args.continuity else 'offline DWS exact detail fixture; fresh cross-source review, actual restart106, no external calls' if args.remote_facts else 'offline composite conditions; current file snapshot, intercepted responses, actual restart102; no external model calls' if args.stage_composites else 'offline cross-stage reference; intercepted requests, fixture stream, actual restart98; no external model calls' if args.stage_references else 'offline parser, production confirmation, receipt binding and fresh local source; actual restart94; no external model requests' if args.created_receipts else 'bounded fact-gap next steps; synthetic sources; actual restart87/92; real model' if args.next_steps else 'saved-key real streaming connection; synthetic contexts; controlled exhausted checkpoint and explicit retry' if args.timeouts else 'typed stage fact criteria; fresh local source reads; actual process restart for77; real model and synthetic data' if args.stage_facts else 'stage revision and field correction; actual process restart for67; real model; synthetic sources' if args.stage_revision else 'structured stage question and same-budget continuation; real model; synthetic sources; actual restart for59' if args.stage_input else 'confirmed bounded stage plans; real model; synthetic business sources; process restart for53/56' if args.stages else 'followup baseline and remote evidence checks; real model; synthetic sources; no business writes' if args.followups else 'bounded remote source tools; real model; synthetic message/document bodies; no real enterprise contents sent' if args.research else 'durable goal restart/revalidation/replay logic; real chat model; controlled external source' if args.goals else 'headless production streaming chat/proposal logic; real model and cancellation' if args.streaming else 'headless production chat logic; controlled delayed-memory extractor; real chat model' if args.experience else 'headless production app logic; controlled remote/time/notification adapters; real process restart for INT-06/07/30'),
               'fullCorpus':not args.experience and not args.streaming and not args.goals and not args.research and not args.followups and not args.stages and not args.stage_input and not args.stage_revision and not args.stage_facts and not args.timeouts and not args.next_steps and not args.created_receipts and not args.stage_references and not args.stage_composites and not args.remote_facts and not args.continuity and not args.correction and not args.preferences and not args.preference_probes and not args.semantic and not args.semantic_probes and not args.todo_cards and not args.todo_card_probe and not args.stage_alternative and not args.stage_alternative_probe and not args.reference_question and not args.reference_question_probe and not args.reference_exclusion and not args.reference_exclusion_probe and len(cases)==30,'missingCases':sorted(known-{r['case_id'] for r in rows})}
    (out/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2))
    print(json.dumps(summary,ensure_ascii=False),flush=True)

if __name__ == '__main__': main()
