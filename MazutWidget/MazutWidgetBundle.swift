//
//  MazutWidgetBundle.swift
//  MazutWidget
//
//  Entry point of the widget extension — contains only the stems Live Activity.
//

import SwiftUI
import WidgetKit

@main
struct MazutWidgetBundle: WidgetBundle {
    var body: some Widget {
        StemLiveActivity()
    }
}
