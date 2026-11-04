//
//  TabHeader.swift
//  Mazut
//
//  Header for the root screen of each tab: a large bold title on the left and
//  the toolbar buttons on the right, all in the same row. On the Songs tab it
//  also carries the ⋮ button that opens the app menu (`SettingsView`).
//
//  The native large title sits on its own row *below* the toolbar, so nothing
//  placed in the toolbar can line up with it. Instead the bar is kept inline,
//  its own title is removed (`toolbar(removing: .title)` — `navigationTitle`
//  is still set, so pushed screens get the right back-button label), and the
//  title is drawn as a leading toolbar item, which shares the row with the
//  trailing buttons.
//

import SwiftUI

extension View {
    /// Root-of-tab header; `showsMenu` adds the ⋮ app-menu button.
    func tabHeader(_ title: String, showsMenu: Bool = false) -> some View {
        modifier(TabHeaderModifier(title: title, showsMenu: showsMenu, hasTrailing: false) { EmptyView() })
    }

    /// Root-of-tab header with extra buttons (e.g. +) on the right.
    func tabHeader<Trailing: View>(_ title: String, showsMenu: Bool = false,
                                   @ViewBuilder trailing: @escaping () -> Trailing) -> some View {
        modifier(TabHeaderModifier(title: title, showsMenu: showsMenu, hasTrailing: true, trailing: trailing))
    }
}

private struct TabHeaderModifier<Trailing: View>: ViewModifier {
    let title: String
    let showsMenu: Bool
    let hasTrailing: Bool
    @ViewBuilder let trailing: () -> Trailing

    @State private var showSettings = false

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text(title)
                        .font(.largeTitle.bold())
                        .lineLimit(1)
                        .fixedSize()
                        .accessibilityAddTraits(.isHeader)
                }
                .sharedBackgroundVisibility(.hidden)

                if hasTrailing {
                    ToolbarItemGroup(placement: .topBarTrailing) { trailing() }
                }

                if showsMenu {
                    if hasTrailing {
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showSettings = true
                        } label: {
                            // Vertical ⋮ — SF Symbols' ellipsis is horizontal.
                            Image(systemName: "ellipsis")
                                .font(.title2.weight(.semibold))
                                .rotationEffect(.degrees(90))
                                .foregroundStyle(.white)
                                .frame(width: 25, height: 25)
//                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Menu")
                    }
                    // No Liquid Glass circle behind the dots.
                    .sharedBackgroundVisibility(.hidden)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
    }
}
