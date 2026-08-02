//
//  AgeGateView.swift
//  Parley
//
//  First-run declared-age gate (App Review Guideline 4.7.5). Presented as a
//  non-dismissable full-screen cover until the user declares a passing birth
//  year. An under-age declaration switches to a persistent blocked screen.
//

import SwiftUI

struct AgeGateView: View {
    @AppStorage(AgeGate.birthYearKey) private var declaredBirthYear = 0
    @State private var selectedYear: Int

    init() {
        _selectedYear = State(initialValue: Calendar.current.component(.year, from: .now) - AgeGate.minimumAge)
    }

    var body: some View {
        if AgeGate.isDeclared(birthYear: declaredBirthYear),
           !AgeGate.passes(birthYear: declaredBirthYear) {
            blocked
        } else {
            declaration
        }
    }

    private var declaration: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text("What year were you born?")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Parley shows unfiltered responses from AI models and web search, so it's rated \(AgeGate.minimumAge)+. Your birth year is stored only on this device and never sent anywhere.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Picker("Birth year", selection: $selectedYear) {
                ForEach(AgeGate.selectableYears(), id: \.self) { year in
                    Text(String(year)).tag(year)
                }
            }
            .pickerStyle(.wheel)
            .frame(maxHeight: 180)
            .accessibilityLabel("Birth year")
            Button {
                declaredBirthYear = selectedYear
            } label: {
                Text("Continue")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal)
            Spacer()
        }
        .padding()
        .interactiveDismissDisabled()
    }

    private var blocked: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "hand.raised.circle")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Parley is for ages \(AgeGate.minimumAge) and up")
                .font(.title2.bold())
                .multilineTextAlignment(.center)
            Text("Based on the birth year you entered, you can't use Parley yet. We're sorry — come back when you're \(AgeGate.minimumAge).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
        }
        .padding()
        .interactiveDismissDisabled()
    }
}

#Preview("Declaration") {
    AgeGateView()
}
