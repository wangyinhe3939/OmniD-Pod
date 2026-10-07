//
//  generic.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 04/08/24.
//

import Foundation
import Defaults

public enum Style {
    case notch
    case floating
}

public enum ContentType: Int, Codable, Hashable, Equatable {
    case normal
    case menu
    case settings
}

public enum NotchState {
    case closed
    case open
}

public enum NotchViews {
    case home
    case shelf
    case extras
}

enum SettingsEnum {
    case general
    case about
    case charge
    case download
    case mediaPlayback
    case hud
    case shelf
    case extensions
}

enum DownloadIndicatorStyle: String, Defaults.Serializable {
    case progress = "Progress"
    case percentage = "Percentage"
}

enum DownloadIconStyle: String, Defaults.Serializable {
    case onlyAppIcon = "Only app icon"
    case onlyIcon = "Only download icon"
    case iconAndAppIcon = "Icon and app icon"
}

enum MirrorShapeEnum: String, Defaults.Serializable {
    case rectangle = "方形"
    case circle = "圆形"
}

enum WindowHeightMode: String, Defaults.Serializable {
    case matchMenuBar = "匹配菜单栏高度"
    case matchRealNotchSize = "匹配实体刘海高度"
    case custom = "自定义高度"
}

enum SliderColorEnum: String, CaseIterable, Defaults.Serializable {
    case white = "白色"
    case albumArt = "匹配专辑封面"
    case accent = "强调色"
}
