import SwiftUI

enum AssistantInspectorPage: String, CaseIterable, Identifiable {
    case workbench = "工作台", memory = "记忆", knowledge = "资料库", skills = "技能", assistant = "助手"
    var id: String { rawValue }
    init?(tab: AssistantTab) {
        switch tab {
        case .chat: return nil
        case .workbench: self = .workbench
        case .memory: self = .memory
        case .knowledge: self = .knowledge
        case .skills: self = .skills
        }
    }
}

struct AssistantHeaderButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(AssistantTheme.text)
            .frame(width: 32, height: 32)
            .background(AssistantTheme.surface.opacity(configuration.isPressed ? 0.65 : 0.95), in: Circle())
            .overlay(Circle().stroke(AssistantTheme.border.opacity(0.4), lineWidth: 1))
    }
}

struct AssistantInspector: View {
    @EnvironmentObject private var model: AssistantModel
    @AppStorage("assistantName") private var assistantName = "予安"
    @Binding var page: AssistantInspectorPage
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                HStack(spacing: 2) {
                    ForEach(AssistantInspectorPage.allCases) { item in
                        Button { page = item } label: {
                            Text(item == .assistant ? assistantName : item.rawValue)
                                .font(.system(size: 12, weight: page == item ? .medium : .regular))
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: item == .assistant ? 66 : nil)
                                .padding(.horizontal, 10).padding(.vertical, 8)
                                .background(page == item ? AssistantTheme.selection : .clear, in: Capsule())
                        }.buttonStyle(.plain)
                            .accessibilityLabel(item == .assistant ? "助手面板" : item.rawValue)
                            .accessibilityAddTraits(page == item ? .isSelected : [])
                    }
                }.padding(5).background(AssistantTheme.surface.opacity(0.85), in: Capsule())
                Spacer(minLength: 0)
                Button(action: onClose) { Image(systemName: "sidebar.right") }
                    .buttonStyle(AssistantHeaderButtonStyle()).accessibilityLabel("关闭侧面板")
            }.padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 12)
            Group {
                switch page {
                case .assistant: AssistantOverview()
                case .workbench: WorkbenchView()
                case .memory: MemoryView()
                case .knowledge: KnowledgeBaseView()
                case .skills: SkillsView()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(AssistantTheme.text)
        .background(LinearGradient(colors: [AssistantTheme.inspectorTop, AssistantTheme.inspectorBottom], startPoint: .top, endPoint: .bottom))
    }

}

private struct AssistantOverview: View {
    @EnvironmentObject private var model: AssistantModel
    @AppStorage("assistantName") private var assistantName = "予安"
    @AppStorage("interfaceAppearance") private var appearance = "system"
    @State private var showingScheduledActivities = false
    @State private var showingMessageSettings = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                VStack(spacing: 12) {
                    Button { model.showingProfile = true } label: {
                        AvatarView(size: 80)
                            .overlay(alignment: .bottomTrailing) {
                                Image(systemName: "pencil").font(.system(size: 11))
                                    .frame(width: 24, height: 24)
                                    .background(AssistantTheme.surface, in: Circle())
                            }
                    }.buttonStyle(.plain).accessibilityLabel("编辑助手")
                    Text(assistantName).font(.system(size: 24, weight: .medium))
                    Text("一起记住重要的事，安排今天")
                        .font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                }.padding(.top, 20)

                VStack(spacing: 10) {
                    HStack {
                        Label("亲密度", systemImage: "sparkles")
                        Spacer()
                        Text(model.relationshipStage.rawValue).foregroundStyle(AssistantTheme.secondaryText)
                    }.font(.system(size: 13))
                    GeometryReader { proxy in
                        Capsule().fill(AssistantTheme.border.opacity(0.5))
                        Capsule().fill(AssistantTheme.accent)
                            .frame(width: proxy.size.width * model.relationshipProgress)
                    }.frame(height: 7)
                    .accessibilityLabel("亲密度进度")
                    .accessibilityValue("\(Int(model.relationshipProgress * 100))%")
                }.padding(18).background(AssistantTheme.surface.opacity(0.55), in: RoundedRectangle(cornerRadius: 24))
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(AssistantTheme.border.opacity(0.4), lineWidth: 1))

                Button { showingScheduledActivities = true } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 20))
                        VStack(alignment: .leading, spacing: 5) {
                            Text("定时任务").font(.system(size: 14, weight: .semibold))
                            Text("每日计划 · 主动提醒").font(.system(size: 12)).foregroundStyle(AssistantTheme.secondaryText)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12))
                    }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AssistantTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain).accessibilityLabel("查看定时任务")

                Button { model.showingConnectionInfo = true } label: {
                    Label("钉钉接入与组织", systemImage: "link")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(AssistantTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)

                Button { showingMessageSettings = true } label: {
                    Label("消息监听设置", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.system(size: 14, weight: .medium))
                        .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                        .background(AssistantTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 14) {
                    Text("最近记忆").font(.system(size: 14, weight: .semibold))
                    if model.memories.isEmpty {
                        Text("慢慢相处，重要的偏好和背景会留在这里。")
                            .font(.system(size: 13)).foregroundStyle(AssistantTheme.secondaryText)
                    }
                    ForEach(Array(model.memories.prefix(3))) { memory in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(memory.category).font(.system(size: 11, weight: .medium))
                                Spacer()
                                Text(memory.createdAt.formatted(date: .abbreviated, time: .omitted))
                                    .font(.system(size: 10)).foregroundStyle(AssistantTheme.secondaryText)
                            }
                            Text(verbatim: memory.content).font(.system(size: 13)).lineSpacing(4)
                                .fixedSize(horizontal: false, vertical: true)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                            .background(AssistantTheme.surface.opacity(0.8), in: RoundedRectangle(cornerRadius: 18))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 16) {
                    Button { model.showingProfile = true } label: {
                        HStack { Label("助手设置", systemImage: "person.crop.circle"); Spacer(); Image(systemName: "chevron.right") }
                    }.buttonStyle(.plain)
                    Divider()
                    Picker("外观", selection: $appearance) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                    }
                }.font(.system(size: 12)).padding(16)
                    .background(AssistantTheme.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 18))
            }.padding(.horizontal, 22).padding(.bottom, 24)
        }.sheet(isPresented: $showingScheduledActivities) { ScheduledActivitiesView() }
            .sheet(isPresented: $showingMessageSettings) { DingTalkEventView() }
    }
}
