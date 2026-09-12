import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Ui
import qs.Commons

// Self-contained drop-down popup for a bar widget. Ui.KeyboardPanel assumes
// the bar lives in a thin layer-shell window and derives the panel geometry
// from `anchorWindow.height`; the Shibumi bar (and other full-height bar
// styles) break that assumption, so this popup positions itself from
// `bar.barSize` / `bar.position` instead, the same way Shibumi's own panels do.
PanelWindow {
  id: root

  required property Item anchorItem
  required property QtObject bar
  property bool open: false
  property int contentWidth: 420
  property int contentHeight: 420
  property Item focusTarget: null

  default property alias content: holder.children
  signal dismissed()

  readonly property var anchorWindow: anchorItem ? anchorItem.QsWindow.window : null
  readonly property string barPos: bar ? bar.position : "top"
  readonly property real barSize: bar ? bar.barSize : 34
  readonly property int gap: Style.gapsOut + 2
  readonly property int margin: Style.gapsOut + 2
  readonly property real screenW: screen ? screen.width : 0
  readonly property real screenH: screen ? screen.height : 0

  // Clamp the card to whatever room the bar leaves on this screen.
  readonly property real maxW: Math.max(160, screenW - margin * 2 - ((barPos === "left" || barPos === "right") ? barSize + gap : 0))
  readonly property real maxH: Math.max(160, screenH - margin * 2 - ((barPos === "top" || barPos === "bottom") ? barSize + gap : 0))
  readonly property real cardW: Math.min(contentWidth, maxW)
  readonly property real cardH: Math.min(contentHeight, maxH)

  // Anchor's position inside the bar window, sampled (not reactively bound —
  // the bar widget does not move during a session).
  property point anchorPos: Qt.point(0, 0)
  function sampleAnchor() {
    if (anchorItem && anchorWindow && anchorWindow.contentItem)
      anchorPos = anchorItem.mapToItem(anchorWindow.contentItem, 0, 0);
  }
  readonly property real anchorW: anchorItem ? anchorItem.width : 0

  readonly property point cardOrigin: {
    var x = anchorPos.x + anchorW / 2 - cardW / 2;
    var y = barSize + gap;
    if (barPos === "bottom") { y = screenH - barSize - cardH - gap; }
    else if (barPos === "left") { x = barSize + gap; y = anchorPos.y - cardH / 2; }
    else if (barPos === "right") { x = screenW - barSize - cardW - gap; y = anchorPos.y - cardH / 2; }
    x = Math.max(margin, Math.min(x, screenW - cardW - margin));
    y = Math.max(margin, Math.min(y, screenH - cardH - margin));
    return Qt.point(Math.round(x), Math.round(y));
  }

  screen: anchorWindow ? anchorWindow.screen : null
  visible: open || card.opacity > 0.01
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  WlrLayershell.namespace: "ayan-nordvpn-panel"
  WlrLayershell.layer: WlrLayer.Overlay
  // Prime with Exclusive so the surface actually receives keys even when the
  // panel is summoned without a pointer click (keybind / IPC), then settle on
  // OnDemand so clicks can still reach the dismissal layer.
  property bool focusPrimed: false
  WlrLayershell.keyboardFocus: open
    ? (focusPrimed ? WlrKeyboardFocus.OnDemand : WlrKeyboardFocus.Exclusive)
    : WlrKeyboardFocus.None

  anchors { top: true; bottom: true; left: true; right: true }

  onOpenChanged: {
    if (open) {
      focusPrimed = false;
      focusPrimeTimer.restart();
      sampleAnchor();
      // one delayed re-sample to catch first-open layout settling, then never
      // again while open — re-sampling on a timer makes the card drift as the
      // bar widget's text reflows.
      resettle.restart();
      if (focusTarget) Qt.callLater(function () { if (root.open && root.focusTarget) root.focusTarget.forceActiveFocus(); });
    } else {
      focusPrimeTimer.stop();
      focusPrimed = false;
    }
  }

  Timer { id: focusPrimeTimer; interval: 80; repeat: false; onTriggered: if (root.open) root.focusPrimed = true }
  Timer { id: resettle; interval: 120; repeat: false; onTriggered: root.sampleAnchor() }

  // Outside-click dismissal.
  MouseArea {
    anchors.fill: parent
    enabled: root.open
    acceptedButtons: Qt.AllButtons
    onPressed: root.dismissed()
  }

  BorderSurface {
    id: card
    x: root.cardOrigin.x
    y: root.cardOrigin.y
    width: root.cardW
    height: root.cardH
    color: Color.popups.background
    borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
    padding: Style.spacing.popupPadding
    radius: Style.cornerRadius
    opacity: root.open ? 1 : 0
    Behavior on opacity { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

    // Swallow clicks so they don't reach the dismissal layer.
    MouseArea { anchors.fill: parent; acceptedButtons: Qt.AllButtons }

    Item {
      id: holder
      anchors.fill: parent
      anchors.topMargin: card.contentTopInset
      anchors.leftMargin: card.contentLeftInset
      anchors.rightMargin: card.contentRightInset
      anchors.bottomMargin: card.contentBottomInset
      clip: true

      Keys.onEscapePressed: root.dismissed()
    }
  }
}
