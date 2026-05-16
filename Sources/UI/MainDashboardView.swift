import SwiftUI

enum SidebarItem: String, CaseIterable, Identifiable {
    case home = "Home"
    case insights = "Insights"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case style = "Style"
    case transforms = "Transforms"
    case scratchpad = "Scratchpad"
    case settings = "Settings"
    
    var id: String { rawValue }
    
    var iconName: String {
        switch self {
        case .home: return "house"
        case .insights: return "chart.bar"
        case .dictionary: return "character.book.closed"
        case .snippets: return "scissors"
        case .style: return "wand.and.stars"
        case .transforms: return "arrow.triangle.2.circlepath"
        case .scratchpad: return "note.text"
        case .settings: return "gearshape"
        }
    }
}

struct MainDashboardView: View {
    @AppStorage("selectedSidebarItem") private var selectedItemRaw: String = SidebarItem.home.rawValue
    
    var selectedItem: SidebarItem? {
        get { SidebarItem(rawValue: selectedItemRaw) }
        set { selectedItemRaw = newValue?.rawValue ?? SidebarItem.home.rawValue }
    }
    
    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                // Custom Header
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 36, height: 36)
                        // Add a subtle shadow if desired, but native app icons usually look great as is
                        .shadow(color: Color.black.opacity(0.1), radius: 3, x: 0, y: 2)
                    
                    Text("Hush")
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                    Spacer()
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 20)
                
                List(selection: Binding(get: { selectedItem }, set: { selectedItemRaw = $0?.rawValue ?? SidebarItem.home.rawValue })) {
                    Section {
                        ForEach(SidebarItem.allCases.dropLast()) { item in
                            NavigationLink(value: item) {
                                Label {
                                    Text(item.rawValue)
                                        .font(.system(size: 14, weight: .medium, design: .rounded))
                                } icon: {
                                    Image(systemName: item.iconName)
                                        .environment(\.symbolVariants, selectedItem == item ? .fill : .none)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                    
                    Spacer()
                        .frame(height: 20)
                    
                    Section {
                        NavigationLink(value: SidebarItem.settings) {
                            Label {
                                Text(SidebarItem.settings.rawValue)
                                    .font(.system(size: 14, weight: .medium, design: .rounded))
                            } icon: {
                                Image(systemName: SidebarItem.settings.iconName)
                                    .environment(\.symbolVariants, selectedItem == .settings ? .fill : .none)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        } detail: {
            ZStack {
                Color(NSColor.textBackgroundColor).ignoresSafeArea()
                
                Group {
                    switch selectedItem {
                    case .home:
                        HomeDashboardView()
                    case .insights:
                        InsightsView()
                    case .dictionary:
                        DictionaryView()
                    case .snippets:
                        SnippetsView()
                    case .style:
                        ComingSoonView(title: "Style", message: "Set up different writing styles for different apps.\nComing soon.")
                    case .transforms:
                        ComingSoonView(title: "Transforms", message: "Create custom text transformation rules.\nComing soon.")
                    case .scratchpad:
                        ScratchpadView()
                    case .settings:
                        FullSettingsView()
                    case .none:
                        Text("Select an item from the sidebar")
                            .font(.title3)
                            .foregroundColor(.secondary)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.2), value: selectedItemRaw)
            }
        }
        .frame(minWidth: 950, minHeight: 650)
    }
}

struct ComingSoonView: View {
    var title: String
    var message: String
    
    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [.accentColor.opacity(0.1), .purple.opacity(0.1)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 100, height: 100)
                
                Image(systemName: "sparkles")
                    .font(.system(size: 40))
                    .foregroundStyle(LinearGradient(colors: [.accentColor, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                
                Text(message)
                    .font(.title3)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .lineSpacing(4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.textBackgroundColor))
    }
}
