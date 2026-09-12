import QtQuick
import QtQuick.Shapes
import qs.Commons

// Interactive equirectangular world map. Country outlines come from
// data/world-paths.json (pre-projected into the viewBox by
// scripts/refresh-data.mjs). Rendering uses QtQuick.Shapes (Canvas is not
// available inside the Quickshell layer surfaces); hit-testing is a manual
// ray-cast over the parsed rings. Colors track the active Omarchy theme.
Item {
  id: root
  clip: true

  // { viewBox: [x,y,w,h], paths: { "US": { d, name, hasServers }, ... } }
  property var geo: ({ viewBox: [0, 0, 1000, 500], paths: {} })
  property string currentCode: ""
  property var favorites: []
  // Highlight colour for current / hover / favourite countries — the plugin
  // passes its theme-derived accent so the map matches the rest of the UI.
  property color accentColor: Color.accent

  signal countryActivated(string code, string name)
  signal countryHovered(string code, string name)

  property string hoverCode: ""
  property real zoom: 1.0
  property real panX: 0
  property real panY: 0

  readonly property var vb: geo && geo.viewBox ? geo.viewBox : [0, 0, 1000, 500]
  readonly property real baseScale: Math.min(width / vb[2], height / vb[3])
  readonly property real mapScale: baseScale * zoom
  readonly property real offsetX: (width - vb[2] * mapScale) / 2 + panX
  readonly property real offsetY: (height - vb[3] * mapScale) / 2 + panY

  // Combined path strings + parsed ring cache, rebuilt when data changes.
  property string _serverPath: ""
  property string _plainPath: ""
  property var _rings: ({})

  property string _favPath: ""
  onGeoChanged: { rebuild(); _favPath = favPath(); }
  onFavoritesChanged: _favPath = favPath()
  Component.onCompleted: { rebuild(); _favPath = favPath(); }

  // code -> [minX, minY, maxX, maxY], to skip ray-casting far-away countries.
  property var _bbox: ({})

  function rebuild() {
    var paths = (geo && geo.paths) || {};
    var serverParts = [], plainParts = [], rings = {}, bbox = {};
    for (var code in paths) {
      var d = paths[code].d;
      if (!d) continue;
      if (paths[code].hasServers) {
        serverParts.push(d);
        var rg = parseD(d);
        rings[code] = rg;
        bbox[code] = ringsBounds(rg);
      } else {
        plainParts.push(d);
      }
    }
    _serverPath = serverParts.join("");
    _plainPath = plainParts.join("");
    _rings = rings;
    _bbox = bbox;
  }

  function ringsBounds(rings) {
    var a = 1e9, b = 1e9, c = -1e9, d = -1e9;
    for (var r = 0; r < rings.length; r++)
      for (var p = 0; p < rings[r].length; p++) {
        var x = rings[r][p][0], y = rings[r][p][1];
        if (x < a) a = x; if (y < b) b = y; if (x > c) c = x; if (y > d) d = y;
      }
    return [a, b, c, d];
  }

  function favPath() {
    var paths = (geo && geo.paths) || {};
    var parts = [];
    for (var i = 0; i < favorites.length; i++) {
      var c = paths[favorites[i]];
      if (c && c.d) parts.push(c.d);
    }
    return parts.join("");
  }

  function dFor(code) {
    var c = ((geo && geo.paths) || {})[code];
    return c ? c.d : "";
  }

  // Our generator emits only "M x y", "L x y", "Z".
  function parseD(d) {
    var tokens = String(d || "").match(/[MLZ]|-?[0-9.]+/g) || [];
    var rings = [], cur = [], i = 0;
    while (i < tokens.length) {
      var t = tokens[i++];
      if (t === "M" || t === "L") {
        var x = parseFloat(tokens[i++]), y = parseFloat(tokens[i++]);
        if (t === "M" && cur.length) { rings.push(cur); cur = []; }
        cur.push([x, y]);
      } else if (t === "Z") {
        if (cur.length) { rings.push(cur); cur = []; }
      }
    }
    if (cur.length) rings.push(cur);
    return rings;
  }

  function codeAt(mx, my) {
    var px = (mx - offsetX) / mapScale;
    var py = (my - offsetY) / mapScale;
    for (var code in _rings) {
      var bb = _bbox[code];
      if (!bb || px < bb[0] || px > bb[2] || py < bb[1] || py > bb[3]) continue;
      if (pointInRings(_rings[code], px, py)) return code;
    }
    return "";
  }

  function pointInRings(rings, x, y) {
    var inside = false;
    for (var r = 0; r < rings.length; r++) {
      var ring = rings[r];
      for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
        var xi = ring[i][0], yi = ring[i][1], xj = ring[j][0], yj = ring[j][1];
        if (((yi > y) !== (yj > y)) && (x < (xj - xi) * (y - yi) / (yj - yi) + xi))
          inside = !inside;
      }
    }
    return inside;
  }

  function resetView() { zoom = 1; panX = 0; panY = 0; }

  // ---------------------------------------------------------------- chrome
  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.04)
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.12)
  }


  Item {
    id: world
    anchors.fill: parent

    // One transformed layer; children draw in raw viewBox coordinates.
    Item {
      width: root.vb[2]
      height: root.vb[3]
      x: root.offsetX
      y: root.offsetY
      transformOrigin: Item.TopLeft
      scale: root.mapScale

      // Base map — tessellated once; the parent Item's `scale`/position is a
      // GPU transform, so panning and zooming never rebuild these paths.
      // Stroke widths are constants (they'd force a re-tessellation on every
      // zoom step if bound to the scale).
      Shape {
        anchors.fill: parent
        asynchronous: true

        ShapePath {
          fillColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.06)
          strokeColor: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.6)
          strokeWidth: 0.35
          PathSvg { path: root._plainPath }
        }
        ShapePath {
          fillColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.22)
          strokeColor: Qt.rgba(Color.popups.background.r, Color.popups.background.g, Color.popups.background.b, 0.9)
          strokeWidth: 0.45
          PathSvg { path: root._serverPath }
        }
      }

      // Highlight layer — small paths that change with state; cheap to rebuild.
      Shape {
        anchors.fill: parent
        asynchronous: true

        ShapePath {
          fillColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.28)
          strokeColor: "transparent"
          PathSvg { path: root._favPath }
        }
        ShapePath {
          fillColor: Qt.rgba(root.accentColor.r, root.accentColor.g, root.accentColor.b, 0.5)
          strokeColor: "transparent"
          PathSvg { path: root.hoverCode && root.hoverCode !== root.currentCode ? root.dFor(root.hoverCode) : "" }
        }
        ShapePath {
          fillColor: root.accentColor
          strokeColor: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.4)
          strokeWidth: 0.6
          PathSvg { path: root.currentCode ? root.dFor(root.currentCode) : "" }
        }
      }
    }
  }

  Timer {
    id: hoverThrottle
    interval: 90
    property real mx: 0
    property real my: 0
    onTriggered: {
      var code = root.codeAt(mx, my);
      if (code !== root.hoverCode) {
        root.hoverCode = code;
        var info = (root.geo.paths || {})[code];
        root.countryHovered(code, info ? info.name : "");
      }
    }
  }

  MouseArea {
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton
    cursorShape: root.hoverCode ? Qt.PointingHandCursor : Qt.ArrowCursor
    property bool dragging: false
    property real lastX: 0
    property real lastY: 0
    property real downX: 0
    property real downY: 0

    onPressed: function (m) { dragging = false; lastX = m.x; lastY = m.y; downX = m.x; downY = m.y; }
    onPositionChanged: function (m) {
      if (m.buttons & Qt.LeftButton) {
        if (Math.abs(m.x - downX) + Math.abs(m.y - downY) > 10) dragging = true;
        if (dragging) {
          root.panX += m.x - lastX;
          root.panY += m.y - lastY;
          lastX = m.x; lastY = m.y;
          root.clampPan();
        }
      } else {
        hoverThrottle.mx = m.x; hoverThrottle.my = m.y;
        if (!hoverThrottle.running) hoverThrottle.restart();
      }
    }
    onReleased: function (m) {
      var moved = Math.abs(m.x - downX) + Math.abs(m.y - downY);
      if (!dragging && moved <= 10) {
        var code = root.codeAt(m.x, m.y);
        if (code) {
          var info = (root.geo.paths || {})[code];
          root.countryActivated(code, info ? info.name : code);
        }
      }
      dragging = false;
    }
    onExited: root.hoverCode = ""
    onWheel: function (w) {
      var factor = w.angleDelta.y > 0 ? 1.15 : 1 / 1.15;
      var nz = Math.max(1, Math.min(8, root.zoom * factor));
      if (nz === root.zoom) return;
      var wx = (w.x - root.offsetX) / root.mapScale;
      var wy = (w.y - root.offsetY) / root.mapScale;
      root.zoom = nz;
      root.panX = w.x - wx * root.mapScale - (root.width - root.vb[2] * root.mapScale) / 2;
      root.panY = w.y - wy * root.mapScale - (root.height - root.vb[3] * root.mapScale) / 2;
      root.clampPan();
    }
  }

  function clampPan() {
    var mx = vb[2] * mapScale * 0.5;
    var my = vb[3] * mapScale * 0.5;
    panX = Math.max(-mx, Math.min(mx, panX));
    panY = Math.max(-my, Math.min(my, panY));
  }

  Rectangle {
    visible: root.zoom > 1.01 || Math.abs(root.panX) > 1 || Math.abs(root.panY) > 1
    x: root.width - width - 6
    y: root.height - height - 6
    width: chipLabel.implicitWidth + 14
    height: chipLabel.implicitHeight + 8
    radius: Style.cornerRadius
    color: Color.popups.background
    border.width: 1
    border.color: Qt.rgba(Color.foreground.r, Color.foreground.g, Color.foreground.b, 0.25)
    Text {
      id: chipLabel
      anchors.centerIn: parent
      text: "Reset view"
      color: Color.foreground
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
    }
    MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.resetView() }
  }
}
