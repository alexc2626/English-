import SwiftUI

struct ContentView: View {
    @State private var profileStore = UserProfileStore()
    @State private var chatViewModel: ChatViewModel?

    var body: some View {
        TabView {
            Group {
                if let chatViewModel {
                    ChatView(viewModel: chatViewModel)
                } else {
                    ProgressView()
                }
            }
            .tabItem { Label("Coach", systemImage: "message.fill") }

            NavigationStack {
                EquipmentSelectionView(profileStore: profileStore)
            }
            .tabItem { Label("Setup", systemImage: "dumbbell.fill") }

            NavigationStack {
                MuscleActivationChartView(breakdown: [:])
                    .navigationTitle("Progress")
            }
            .tabItem { Label("Progress", systemImage: "chart.pie.fill") }
        }
        .task {
            if chatViewModel == nil {
                chatViewModel = ChatViewModel(profileStore: profileStore)
            }
        }
        .onChange(of: profileStore.selectedEquipment) {
            chatViewModel?.rebuildSession()
        }
    }
}

#Preview {
    ContentView()
}
