import SwiftUI
import Charts

/// Donut chart summarizing which muscle groups were trained most in a session.
struct MuscleActivationChartView: View {
    let breakdown: [MuscleGroup: Double]

    private var sortedEntries: [(muscle: MuscleGroup, volume: Double)] {
        breakdown
            .map { (muscle: $0.key, volume: $0.value) }
            .sorted { $0.volume > $1.volume }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Muscles Trained This Session")
                .font(.headline)

            if sortedEntries.isEmpty {
                Text("Log a workout to see your muscle activation breakdown.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(sortedEntries, id: \.muscle) { entry in
                    SectorMark(
                        angle: .value("Volume", entry.volume),
                        innerRadius: .ratio(0.6),
                        angularInset: 1.5
                    )
                    .cornerRadius(4)
                    .foregroundStyle(by: .value("Muscle", entry.muscle.displayName))
                }
                .chartLegend(position: .bottom, alignment: .center, spacing: 8)
                .frame(height: 280)
            }
        }
        .padding()
    }
}

#Preview {
    MuscleActivationChartView(breakdown: [
        .quads: 42, .glutes: 38, .hamstrings: 21, .core: 18, .obliques: 14
    ])
}
