import BoseKit
import Cocoa

/// Base layout for an `NSMenuItem` custom view containing a leading SF Symbol,
/// a slider, and a trailing monospaced value label.
@MainActor
public class MenuSliderRowView: NSView {
  public let iconView = NSImageView()
  public let slider = NSSlider()
  public let valueLabel = NSTextField(labelWithString: "")

  init(
    symbolName: String,
    valueText: String,
    labelWidth: CGFloat,
    minValue: Double,
    maxValue: Double,
    currentValue: Double,
    target: AnyObject?,
    action: Selector
  ) {
    super.init(frame: NSRect(x: 0, y: 0, width: 230, height: 32))
    autoresizingMask = [.width]

    iconView.frame = NSRect(x: 14, y: 8, width: 16, height: 16)
    iconView.image = Self.templateSymbol(symbolName)
    iconView.contentTintColor = .secondaryLabelColor
    addSubview(iconView)

    let labelX = 216 - labelWidth
    valueLabel.frame = NSRect(x: labelX, y: 8, width: labelWidth, height: 16)
    valueLabel.stringValue = valueText
    valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    valueLabel.textColor = .secondaryLabelColor
    valueLabel.alignment = .right
    valueLabel.autoresizingMask = [.minXMargin]
    addSubview(valueLabel)

    slider.minValue = minValue
    slider.maxValue = maxValue
    slider.doubleValue = currentValue
    slider.target = target
    slider.action = action
    slider.frame = NSRect(x: 36, y: 6, width: labelX - 42, height: 20)
    slider.controlSize = .small
    slider.isContinuous = true
    slider.autoresizingMask = [.width]
    addSubview(slider)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  static func templateSymbol(_ name: String) -> NSImage? {
    let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    img?.isTemplate = true
    return img
  }
}

/// Menu slider row for Noise Control (Bose 0–10 scale, 10 = Quiet / max ANC).
@MainActor
public final class NoiseLevelSliderView: MenuSliderRowView {
  public init(current: Int, target: AnyObject?, action: Selector) {
    super.init(
      symbolName: current >= 5 ? "waveform.slash" : "ear",
      valueText: "Level \(current)",
      labelWidth: 48,
      minValue: 0,
      maxValue: 10,
      currentValue: Double(current),
      target: target,
      action: action
    )
    slider.numberOfTickMarks = 11
    slider.allowsTickMarkValuesOnly = true
    slider.tickMarkPosition = .below
  }

  public func update(displayed: Int, syncSlider: Bool = false) {
    if syncSlider && Int(round(slider.doubleValue)) != displayed {
      slider.doubleValue = Double(displayed)
    }
    valueLabel.stringValue = "Level \(displayed)"
    iconView.image = Self.templateSymbol(displayed >= 5 ? "waveform.slash" : "ear")
  }
}

/// Menu slider row for headphone remote volume.
@MainActor
public final class VolumeSliderView: MenuSliderRowView {
  public init(current: Int, max: Int, target: AnyObject?, action: Selector) {
    let maxVal = max > 0 ? max : 16
    let pct = VolumeInfo(current: UInt8(clamping: current), max: UInt8(clamping: maxVal)).percentage
    super.init(
      symbolName: Self.symbolName(for: current),
      valueText: "\(pct)%",
      labelWidth: 36,
      minValue: 0,
      maxValue: Double(maxVal),
      currentValue: Double(current),
      target: target,
      action: action
    )
  }

  public func update(current: UInt8, max: UInt8, syncSlider: Bool = false) {
    let maxVal = max > 0 ? max : 16
    if syncSlider {
      slider.maxValue = Double(maxVal)
      if UInt8(clamping: Int(round(slider.doubleValue))) != current {
        slider.doubleValue = Double(current)
      }
    }
    let pct = VolumeInfo(current: current, max: maxVal).percentage
    valueLabel.stringValue = "\(pct)%"
    iconView.image = Self.templateSymbol(Self.symbolName(for: Int(current)))
  }

  private static func symbolName(for level: Int) -> String {
    if level == 0 { return "speaker.slash.fill" }
    return level <= 8 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
  }
}
