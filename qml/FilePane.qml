import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import QtQuick.Effects
import app.loaf

// One file view (grid + list) bound to its own LoafEngine model. Used for
// every tab and for both sides of the split view.
//
// Selection is kept by *path* (not row number) so it survives rows being
// inserted or removed while the folder changes on disk.
Item {
    id: pane

    property alias engine: paneEngine
    property bool isActive: true
    property bool showHeader: true

    // { "/abs/path": true }
    property var selection: ({})
    readonly property int selectedCount: Object.keys(selection).length
    property string anchorPath: ""
    property string cursorPath: ""
    // Path whose name is being edited inline ("" = none).
    property string renamingPath: ""
    // Selected after the next load (new folder, pasted items, ...).
    property var pendingSelect: []
    property bool pendingRename: false

    signal activated()

    LoafEngine {
        id: paneEngine
        onCurrent_pathChanged: {
            pane.clearSelection();
            pane.renamingPath = "";
            // Pending selections belong to the folder they were made for.
            pane.pendingSelect = [];
            pane.pendingRename = false;
            if (theme.animate)
                enterAnim.restart();
        }
        onLoaded: pane.afterLoad()
        // Filtering and hidden-file toggles hide rows without a reload:
        // hidden items must not stay selected (Delete would hit them).
        onFilter_textChanged: Qt.callLater(pane.trimSelection)
        onShow_hiddenChanged: Qt.callLater(pane.trimSelection)
    }

    // Apply right away when the items are already listed (the watcher may
    // have reloaded before the operation reported back).
    onPendingSelectChanged: if (pendingSelect.length > 0 && !paneEngine.loading) Qt.callLater(afterLoad)

    function trimSelection() {
        if (selectedCount === 0)
            return;
        var kept = JSON.parse(paneEngine.filter_existing(JSON.stringify(Object.keys(selection))));
        if (kept.length !== selectedCount) {
            var s = {};
            for (var j = 0; j < kept.length; ++j)
                s[kept[j]] = true;
            selection = s;
            if (!s[cursorPath])
                cursorPath = kept.length > 0 ? kept[kept.length - 1] : "";
            if (!s[anchorPath])
                anchorPath = kept.length > 0 ? kept[0] : "";
        }
    }

    function afterLoad() {
        if (pendingSelect.length > 0) {
            var sel = {};
            var first = "";
            for (var i = 0; i < pendingSelect.length; ++i) {
                if (paneEngine.row_of(pendingSelect[i]) >= 0) {
                    sel[pendingSelect[i]] = true;
                    if (!first)
                        first = pendingSelect[i];
                }
            }
            if (first) {
                selection = sel;
                anchorPath = first;
                cursorPath = first;
                ensureVisible(paneEngine.row_of(first));
                if (pendingRename) {
                    var target = first;
                    Qt.callLater(function() { pane.renamingPath = target; });
                }
                pendingSelect = [];
                pendingRename = false;
            }
        } else {
            // Drop paths that vanished (deleted / renamed elsewhere).
            trimSelection();
        }
    }

    // ---- selection API (used by main.qml) ---------------------------------

    function selectedPaths() {
        return Object.keys(selection);
    }

    function selectedItems() {
        var out = [];
        var paths = selectedPaths();
        for (var i = 0; i < paths.length; ++i) {
            var row = paneEngine.row_of(paths[i]);
            if (row >= 0)
                out.push(JSON.parse(paneEngine.item_json(row)));
        }
        return out;
    }

    function clearSelection() {
        selection = {};
        anchorPath = "";
        cursorPath = "";
    }

    function selectPaths(paths) {
        var s = {};
        for (var i = 0; i < paths.length; ++i)
            s[paths[i]] = true;
        selection = s;
        if (paths.length > 0) {
            anchorPath = paths[0];
            cursorPath = paths[paths.length - 1];
        }
    }

    function selectAll() {
        selectPaths(JSON.parse(paneEngine.paths_in_range(0, paneEngine.item_count - 1)));
    }

    function invertSelection() {
        var all = JSON.parse(paneEngine.paths_in_range(0, paneEngine.item_count - 1));
        var s = {};
        for (var i = 0; i < all.length; ++i) {
            if (!selection[all[i]])
                s[all[i]] = true;
        }
        selection = s;
    }

    function selectPattern(pattern) {
        var rows = JSON.parse(paneEngine.rows_matching(pattern));
        var s = {};
        for (var i = 0; i < rows.length; ++i)
            s[paneEngine.path_at(rows[i])] = true;
        selection = s;
    }

    function cols() {
        return isList() ? 1 : Math.max(1, Math.floor(gridView.width / gridView.cellWidth));
    }

    function isList() {
        return paneEngine.view_mode === "list";
    }

    // Grid shift-selection is rectangular (the item directly underneath),
    // list shift-selection is a contiguous range.
    function rangeSelect(fromRow, toRow) {
        if (isList()) {
            var paths = JSON.parse(paneEngine.paths_in_range(fromRow, toRow));
            var s = {};
            for (var i = 0; i < paths.length; ++i)
                s[paths[i]] = true;
            return s;
        }
        var c = cols();
        var r1 = Math.floor(fromRow / c), r2 = Math.floor(toRow / c);
        var c1 = fromRow % c, c2 = toRow % c;
        var out = {};
        for (var r = Math.min(r1, r2); r <= Math.max(r1, r2); ++r) {
            for (var cc = Math.min(c1, c2); cc <= Math.max(c1, c2); ++cc) {
                var idx = r * c + cc;
                if (idx < paneEngine.item_count)
                    out[paneEngine.path_at(idx)] = true;
            }
        }
        return out;
    }

    function selectRow(row, ctrl, shift) {
        var p = paneEngine.path_at(row);
        if (!p)
            return;
        if (shift) {
            var a = anchorPath ? paneEngine.row_of(anchorPath) : -1;
            if (a < 0)
                a = row;
            selection = rangeSelect(a, row);
        } else if (ctrl) {
            var copy = Object.assign({}, selection);
            if (copy[p])
                delete copy[p];
            else
                copy[p] = true;
            selection = copy;
            anchorPath = p;
        } else {
            var one = {};
            one[p] = true;
            selection = one;
            anchorPath = p;
        }
        cursorPath = p;
    }

    function moveSelection(dx, dy, shift) {
        var n = paneEngine.item_count;
        if (n === 0)
            return;
        var c = cols();
        var cur = cursorPath ? paneEngine.row_of(cursorPath) : -1;
        var target;
        if (cur < 0)
            target = 0;
        else if (isList())
            target = cur + (dy !== 0 ? dy : dx);
        else
            target = cur + dx + dy * c;
        target = Math.max(0, Math.min(n - 1, target));
        selectRow(target, false, shift);
        ensureVisible(target);
    }

    function ensureVisible(row) {
        if (row < 0)
            return;
        if (isList())
            listView.positionViewAtIndex(row, ListView.Contain);
        else
            gridView.positionViewAtIndex(row, GridView.Contain);
    }

    function selectFirstMatch(prefix) {
        var rows = JSON.parse(paneEngine.rows_matching(prefix + "*"));
        if (rows.length > 0) {
            selectRow(rows[0], false, false);
            ensureVisible(rows[0]);
        }
    }

    function startRename() {
        var paths = selectedPaths();
        if (paths.length === 1 && !paneEngine.read_only && paneEngine.location_kind !== "trash")
            renamingPath = paths[0];
    }

    function cancelRename() {
        renamingPath = "";
        window.defocusInputs();
    }

    function commitRename(path, newName) {
        renamingPath = "";
        // The editor took keyboard focus; give it back to the window's key
        // handler so arrows and type-to-filter keep working.
        window.defocusInputs();
        var oldName = path.substring(path.lastIndexOf("/") + 1);
        if (newName.trim().length === 0 || newName === oldName)
            return;
        var err = core.rename_item(path, newName);
        if (err.length > 0) {
            window.toast("error", err);
        } else {
            var parent = path.substring(0, path.lastIndexOf("/"));
            pendingSelect = [parent + "/" + newName.trim()];
        }
    }

    function openRow(row) {
        var p = paneEngine.path_at(row);
        if (!p)
            return;
        var item = JSON.parse(paneEngine.item_json(row));
        window.openItem(pane, item);
    }

    function openSelected() {
        var items = selectedItems();
        if (items.length === 1) {
            window.openItem(pane, items[0]);
        } else if (items.length > 1) {
            // Several files: open each (folders open as new tabs).
            for (var i = 0; i < items.length; ++i) {
                if (items[i].is_dir)
                    window.openInNewTab(items[i].path);
                else
                    core.open_item(items[i].path);
            }
        }
    }

    // Converts drop URLs to local paths (percent-decoded).
    function urlsToPaths(urls) {
        var out = [];
        for (var i = 0; i < urls.length; ++i) {
            var u = urls[i].toString();
            if (u.indexOf("file://") !== 0)
                continue;
            var raw = u.substring(7);
            try {
                out.push(decodeURIComponent(raw));
            } catch (e) {
                out.push(raw);
            }
        }
        return out;
    }

    function handleDropOn(drop, destPath, mouseItem) {
        dragManager.hoverTarget = "";
        if (!drop.hasUrls || paneEngine.read_only)
            return;
        var paths = urlsToPaths(drop.urls).filter(function(p) { return p !== destPath; });
        if (paths.length === 0)
            return;
        var asCopy = (drop.source === dragProxy)
            ? dragManager.asCopy
            : ((drop.proposedAction === Qt.CopyAction) || !(drop.supportedActions & Qt.MoveAction));
        drop.accept(asCopy ? Qt.CopyAction : Qt.MoveAction);
        if (dragManager.isRmb && mouseItem) {
            var pt = mouseItem.mapToItem(window.contentItem, drop.x, drop.y);
            rmbDropMenu.showAt(pt.x, pt.y, paths, destPath);
        } else {
            window.handleDrop(paths, destPath, asCopy);
        }
    }

    function dropTargetDir() {
        return paneEngine.location_kind === "dir" ? paneEngine.current_path : "";
    }

    readonly property real zoom: theme.zoom
    readonly property int cellW: Math.round(124 * zoom)
    readonly property int cellH: Math.round(114 * zoom)
    readonly property int iconSize: Math.round(42 * zoom)

    ParallelAnimation {
        id: enterAnim
        NumberAnimation { target: stage; property: "opacity"; from: 0.25; to: 1.0; duration: 170; easing.type: Easing.OutCubic }
        NumberAnimation { target: stageShift; property: "y"; from: 10; to: 0; duration: 190; easing.type: Easing.OutCubic }
    }

    ColumnLayout {
        anchors.fill: parent
        spacing: 12

        // Title, item count and selection count.
        RowLayout {
            visible: pane.showHeader
            Layout.fillWidth: true
            spacing: 10

            Text {
                id: heroTitle
                text: paneEngine.is_searching_everywhere
                    ? (paneEngine.searching ? qsTr("Searching…") : qsTr("Search results"))
                    : paneEngine.current_dir_name
                color: theme.textMain
                font.pixelSize: theme.fs(24)
                font.bold: true
                font.letterSpacing: -0.5
                elide: Text.ElideRight
                Layout.fillWidth: true
                Layout.minimumWidth: 60
                Accessible.role: Accessible.Heading
            }

            Rectangle {
                visible: pane.selectedCount > 0
                Layout.preferredHeight: 28
                Layout.preferredWidth: selLabel.implicitWidth + 20
                radius: theme.radiusFull
                color: theme.primaryContainer
                Text {
                    id: selLabel
                    anchors.centerIn: parent
                    text: qsTr("%1 selected").arg(theme.number(pane.selectedCount))
                    color: theme.primaryContainerFg
                    font.pixelSize: theme.fs(11)
                    font.bold: true
                }
            }

            Rectangle {
                Layout.preferredHeight: 28
                Layout.preferredWidth: countLabel.implicitWidth + 18
                radius: theme.radiusFull
                color: theme.surfaceContainerHigh
                Text {
                    id: countLabel
                    anchors.centerIn: parent
                    text: paneEngine.is_searching_everywhere
                        ? theme.plural(paneEngine.item_count, qsTr("1 result"), qsTr("%1 results"))
                        : theme.plural(paneEngine.item_count, qsTr("1 item"), qsTr("%1 items"))
                    color: theme.textMuted
                    font.pixelSize: theme.fs(11)
                    font.bold: true
                }
            }
        }

        Item {
            id: stage
            Layout.fillWidth: true
            Layout.fillHeight: true
            transform: Translate { id: stageShift; y: 0 }

            // Empty / error / loading states.
            ColumnLayout {
                anchors.centerIn: parent
                spacing: 10
                visible: paneEngine.item_count === 0 && (!paneEngine.loading || paneEngine.error_text.length > 0)
                z: 5

                LoafIcon {
                    Layout.alignment: Qt.AlignHCenter
                    name: paneEngine.error_text.length > 0 ? "warning"
                        : (paneEngine.location_kind === "trash" ? "trash"
                        : (paneEngine.is_searching_everywhere ? "magnifying-glass" : "folder-open"))
                    size: 44
                    color: theme.textMuted
                }
                Text {
                    Layout.alignment: Qt.AlignHCenter
                    text: paneEngine.error_text.length > 0 ? paneEngine.error_text
                        : (paneEngine.filter_text.length > 0 ? qsTr("No matching files")
                        : (paneEngine.is_searching_everywhere ? qsTr("No results")
                        : (paneEngine.location_kind === "trash" ? qsTr("Trash is empty")
                        : (paneEngine.location_kind === "recent" ? qsTr("No recent files")
                        : (paneEngine.location_kind === "starred" ? qsTr("Nothing starred yet") : qsTr("This folder is empty"))))))
                    color: theme.textMuted
                    font.pixelSize: theme.fs(14)
                    font.bold: true
                }
            }

            // Small spinner while a scan / search runs.
            LoafIcon {
                id: spinner
                visible: paneEngine.loading && paneEngine.item_count === 0 && paneEngine.error_text.length === 0
                anchors.centerIn: parent
                name: "hourglass"
                size: 30
                color: theme.textMuted
                // Must stop when hidden: a running animator redraws every frame.
                RotationAnimator on rotation {
                    running: spinner.visible && theme.animate
                    from: 0; to: 360; duration: 1200; loops: Animation.Infinite
                }
            }

            // Background: deselect, empty-area menu, drops into this folder.
            DropArea {
                anchors.fill: parent
                keys: ["text/uri-list"]
                onDropped: function(drop) {
                    if (dragManager.hoverTarget.length > 0 || pane.dropTargetDir().length === 0)
                        return;
                    pane.handleDropOn(drop, pane.dropTargetDir(), null);
                }
            }

            // ===================== GRID =====================
            GridView {
                id: gridView
                anchors.fill: parent
                visible: !pane.isList()
                enabled: visible
                clip: true
                cellWidth: pane.cellW
                cellHeight: pane.cellH
                cacheBuffer: theme.lowPower ? 0 : cellHeight * 2
                boundsBehavior: Flickable.StopAtBounds
                interactive: true
                model: visible ? paneEngine : null
                focus: false
                Accessible.role: Accessible.List
                Accessible.name: paneEngine.current_dir_name

                add: Transition {
                    enabled: theme.animate
                    ParallelAnimation {
                        NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 200 }
                        NumberAnimation { property: "scale"; from: 0.75; to: 1.0; duration: 240; easing.type: Easing.OutBack }
                    }
                }
                displaced: Transition {
                    enabled: theme.animate
                    NumberAnimation { properties: "x,y"; duration: 240; easing.type: Easing.OutCubic }
                }

                ScrollBar.vertical: ScrollBar {
                    id: gridScroll
                    policy: ScrollBar.AsNeeded
                    width: 12
                    padding: 2
                    contentItem: Rectangle {
                        implicitWidth: 6
                        radius: 3
                        color: gridScroll.pressed ? theme.primary : (gridScroll.hovered ? theme.outline : theme.outlineVariant)
                        opacity: gridScroll.active ? 1.0 : 0.0
                        Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: 200 } }
                    }
                }

                WheelHandler {
                    target: null
                    acceptedModifiers: Qt.NoModifier
                    onWheel: function(event) {
                        var step = 80 * pane.zoom;
                        var maxY = Math.max(0, gridView.contentHeight - gridView.height);
                        gridView.contentY = Math.max(0, Math.min(maxY, gridView.contentY - (event.angleDelta.y > 0 ? step : -step)));
                    }
                }
                WheelHandler {
                    target: null
                    acceptedModifiers: Qt.ControlModifier
                    onWheel: function(event) { theme.stepZoom(event.angleDelta.y > 0 ? 1 : -1); }
                }

                // Rubber band selection.
                Rectangle {
                    id: band
                    parent: gridView.contentItem
                    z: 100
                    visible: false
                    color: Qt.rgba(theme.primary.r, theme.primary.g, theme.primary.b, theme.isDark ? 0.22 : 0.16)
                    border.color: theme.primary
                    border.width: 1.5
                    radius: theme.radiusM
                }

                MouseArea {
                    id: bgMouse
                    parent: gridView.contentItem
                    width: Math.max(gridView.width, gridView.contentWidth)
                    height: Math.max(gridView.height + gridView.contentY, gridView.contentHeight)
                    z: -1
                    acceptedButtons: Qt.LeftButton | Qt.RightButton
                    preventStealing: theme.dragAction === "select"

                    property real sx: 0
                    property real sy: 0
                    property bool active: false
                    property bool justDragged: false
                    property var base: ({})

                    function updateBand(mx, my) {
                        var x = Math.min(sx, mx), y = Math.min(sy, my);
                        var w = Math.abs(mx - sx), h = Math.abs(my - sy);
                        band.x = x; band.y = y; band.width = w; band.height = h;
                        var cw = gridView.cellWidth, ch = gridView.cellHeight;
                        var c = pane.cols();
                        var sel = Object.assign({}, base);
                        // Only the rows under the box are visited.
                        var r1 = Math.max(0, Math.floor(y / ch)), r2 = Math.floor((y + h) / ch);
                        var c1 = Math.max(0, Math.floor(x / cw)), c2 = Math.min(c - 1, Math.floor((x + w) / cw));
                        for (var r = r1; r <= r2; ++r) {
                            for (var cc = c1; cc <= c2; ++cc) {
                                var idx = r * c + cc;
                                if (idx >= paneEngine.item_count)
                                    break;
                                var l = cc * cw + 4, t = r * ch + 4;
                                if (x < l + cw - 8 && x + w > l && y < t + ch - 8 && y + h > t)
                                    sel[paneEngine.path_at(idx)] = true;
                            }
                        }
                        pane.selection = sel;
                    }

                    onPressed: function(mouse) {
                        pane.activated();
                        window.defocusInputs();
                        if (mouse.button !== Qt.LeftButton || theme.dragAction !== "select")
                            return;
                        sx = mouse.x; sy = mouse.y;
                        active = false;
                        base = (mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)) ? Object.assign({}, pane.selection) : {};
                    }
                    onPositionChanged: function(mouse) {
                        if (theme.dragAction !== "select" || !(mouse.buttons & Qt.LeftButton))
                            return;
                        if (!active && (Math.abs(mouse.x - sx) + Math.abs(mouse.y - sy)) > 6) {
                            active = true;
                            band.visible = true;
                        }
                        if (active)
                            updateBand(mouse.x, mouse.y);
                    }
                    onReleased: {
                        if (active) {
                            active = false;
                            band.visible = false;
                            justDragged = true;
                            resetDragged.restart();
                        }
                    }
                    onCanceled: { active = false; band.visible = false; }
                    onClicked: function(mouse) {
                        if (justDragged)
                            return;
                        if (mouse.button === Qt.RightButton) {
                            var pt = mapToItem(window.contentItem, mouse.x, mouse.y);
                            window.openEmptyMenu(pane, pt.x, pt.y);
                        } else {
                            pane.clearSelection();
                        }
                    }
                    Timer { id: resetDragged; interval: 60; onTriggered: bgMouse.justDragged = false }
                    // Scroll while dragging the band past the edges.
                    Timer {
                        interval: 20
                        repeat: true
                        running: bgMouse.active
                        onTriggered: {
                            var my = bgMouse.mouseY;
                            var top = gridView.contentY, bottom = top + gridView.height;
                            var maxY = Math.max(0, gridView.contentHeight - gridView.height);
                            if (my < top + 32 && gridView.contentY > 0)
                                gridView.contentY = Math.max(0, gridView.contentY - 12);
                            else if (my > bottom - 32 && gridView.contentY < maxY)
                                gridView.contentY = Math.min(maxY, gridView.contentY + 12);
                            else
                                return;
                            bgMouse.updateBand(bgMouse.mouseX, bgMouse.mouseY);
                        }
                    }
                }

                delegate: Item {
                    id: card
                    width: gridView.cellWidth
                    height: gridView.cellHeight

                    required property int index
                    required property string name
                    required property string path
                    required property bool is_dir
                    required property bool is_symlink
                    required property string icon
                    required property string system_icon
                    required property bool thumbable
                    required property string thumb_id
                    required property string display_name
                    required property bool starred

                    readonly property bool isSelected: !!pane.selection[path]
                    readonly property bool isCut: !!window.cutSet[path]
                    readonly property int col: index % Math.max(1, Math.floor(gridView.width / gridView.cellWidth))
                    readonly property bool hasLeft: isSelected && col > 0 && !!pane.selection[paneEngine.path_at(index - 1)]
                    readonly property bool hasRight: isSelected && col < pane.cols() - 1 && index + 1 < paneEngine.item_count && !!pane.selection[paneEngine.path_at(index + 1)]
                    readonly property bool isDropTarget: is_dir && folderDrop.containsDrag
                    readonly property bool hasThumb: theme.showThumbnails && thumbable && thumbImg.status === Image.Ready
                    readonly property bool isCursor: window.keyboardNavActive && pane.isActive && pane.cursorPath === path

                    Accessible.role: Accessible.ListItem
                    Accessible.name: name
                    Accessible.selected: isSelected

                    opacity: isCut ? 0.5 : 1.0

                    property bool entered: !theme.animate
                    Component.onCompleted: entered = true

                    DropArea {
                        id: folderDrop
                        anchors.fill: parent
                        enabled: card.is_dir && !paneEngine.read_only
                        keys: ["text/uri-list"]
                        onEntered: dragManager.hover(card.path, paneEngine)
                        onExited: if (dragManager.hoverTarget === card.path) dragManager.hoverTarget = ""
                        onDropped: function(drop) { pane.handleDropOn(drop, card.path, card); }
                    }

                    Rectangle {
                        id: highlight
                        anchors.fill: parent
                        anchors.topMargin: 4
                        anchors.bottomMargin: 4
                        anchors.leftMargin: card.hasLeft ? -4 : 4
                        anchors.rightMargin: card.hasRight ? -4 : 4
                        radius: theme.radiusL
                        color: card.isDropTarget
                            ? Qt.rgba(theme.primary.r, theme.primary.g, theme.primary.b, theme.isDark ? 0.20 : 0.14)
                            : (card.isSelected ? theme.secondaryContainer : (cardMouse.pressed ? theme.activeOverlay : theme.hoverOverlay))
                        opacity: (card.isSelected || cardMouse.containsMouse || card.isDropTarget) ? 1.0 : 0.0
                        border.color: card.isCursor || card.isDropTarget ? theme.primary : "transparent"
                        border.width: card.isCursor || card.isDropTarget ? 2 : 0
                        Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: theme.durationFast } }

                        Rectangle {
                            visible: card.hasRight
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width / 2
                            color: parent.color
                        }
                        Rectangle {
                            visible: card.hasLeft
                            anchors.left: parent.left
                            anchors.top: parent.top
                            anchors.bottom: parent.bottom
                            width: parent.width / 2
                            color: parent.color
                        }
                    }

                    scale: !entered ? 0.82
                        : (cardMouse.pressed ? 0.94 : ((cardMouse.containsMouse && !card.hasLeft && !card.hasRight) ? 1.03 : 1.0))
                    Behavior on scale { enabled: theme.animate; SpringAnimation { spring: 3.5; damping: 0.3 } }

                    ColumnLayout {
                        anchors.fill: parent
                        anchors.margins: 12 * pane.zoom
                        spacing: 6

                        Item { Layout.fillHeight: true }

                        Item {
                            Layout.alignment: Qt.AlignHCenter
                            Layout.preferredWidth: Math.round(46 * pane.zoom)
                            Layout.preferredHeight: Math.round(46 * pane.zoom)

                            LoafIcon {
                                visible: !card.hasThumb && theme.iconSource === "phosphor"
                                anchors.centerIn: parent
                                name: card.isCut ? (card.is_dir ? "folder-dashed" : "file-dashed") : (card.icon || "file")
                                size: pane.iconSize
                                color: card.isSelected ? theme.secondaryContainerFg : (card.is_dir ? theme.primary : theme.textMain)
                            }

                            Image {
                                visible: !card.hasThumb && theme.iconSource !== "phosphor"
                                anchors.centerIn: parent
                                source: theme.iconSource !== "phosphor" ? window.systemIcon(card.system_icon) : ""
                                width: pane.iconSize + 2
                                height: pane.iconSize + 2
                                sourceSize.width: 64 * pane.zoom
                                sourceSize.height: 64 * pane.zoom
                                fillMode: Image.PreserveAspectFit
                                asynchronous: true
                            }

                            Item {
                                anchors.fill: parent
                                visible: card.hasThumb

                                Rectangle {
                                    id: thumbMask
                                    anchors.fill: parent
                                    radius: theme.radiusM
                                    color: "white"
                                    visible: false
                                    layer.enabled: card.hasThumb && !theme.lowPower
                                }

                                Image {
                                    id: thumbImg
                                    anchors.fill: parent
                                    source: theme.showThumbnails && card.thumbable && card.thumb_id.length > 0
                                        ? ("image://thumb/" + card.thumb_id) : ""
                                    fillMode: Image.PreserveAspectCrop
                                    sourceSize.width: Math.round(48 * pane.zoom)
                                    sourceSize.height: Math.round(48 * pane.zoom)
                                    asynchronous: true
                                    cache: true
                                    smooth: true
                                    // The rounded mask costs an offscreen layer:
                                    // only for real thumbnails, never in low-power mode.
                                    layer.enabled: card.hasThumb && !theme.lowPower
                                    layer.effect: MultiEffect {
                                        maskEnabled: true
                                        maskSource: thumbMask
                                    }
                                }

                                Rectangle {
                                    anchors.fill: parent
                                    radius: theme.radiusM
                                    color: "transparent"
                                    border.color: card.isSelected ? theme.primary : theme.outlineVariant
                                    border.width: 1
                                    opacity: card.isSelected ? 0.75 : 0.35
                                }
                            }

                            // Symlink / star badges.
                            Rectangle {
                                visible: card.is_symlink
                                width: 14; height: 14; radius: 7
                                color: theme.surfaceContainer
                                border.color: theme.outlineVariant
                                border.width: 1
                                anchors.bottom: parent.bottom
                                anchors.right: parent.right
                                LoafIcon { anchors.centerIn: parent; name: "arrow-square-out"; size: 9; color: theme.primary }
                            }
                            LoafIcon {
                                visible: card.starred
                                anchors.top: parent.top
                                anchors.right: parent.right
                                anchors.margins: -4
                                name: "star"
                                size: 13
                                color: theme.primary
                            }
                        }

                        Loader {
                            Layout.fillWidth: true
                            Layout.preferredHeight: 30
                            active: true
                            sourceComponent: pane.renamingPath === card.path ? renameEditor : nameLabel

                            Component {
                                id: nameLabel
                                Text {
                                    text: paneEngine.is_searching_everywhere ? (card.display_name || card.name) : card.name
                                    color: card.isSelected ? theme.secondaryContainerFg : theme.textMain
                                    font.pixelSize: theme.fs(11)
                                    font.bold: card.is_dir || card.isSelected
                                    horizontalAlignment: Text.AlignHCenter
                                    verticalAlignment: Text.AlignTop
                                    wrapMode: Text.WrapAnywhere
                                    maximumLineCount: 2
                                    elide: Text.ElideMiddle
                                }
                            }
                            Component {
                                id: renameEditor
                                InlineRename {
                                    originalName: card.name
                                    isDir: card.is_dir
                                    onCommit: function(text) { pane.commitRename(card.path, text); }
                                    onCancel: pane.cancelRename()
                                }
                            }
                        }

                        Item { Layout.fillHeight: true }
                    }

                    MouseArea {
                        id: cardMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        preventStealing: true
                        onWheel: function(wheel) { wheel.accepted = false; }

                        property point pressPt
                        property bool dragging: false

                        onPressed: function(mouse) {
                            pane.activated();
                            window.defocusInputs();
                            pressPt = Qt.point(mouse.x, mouse.y);
                            dragging = false;
                            if (mouse.button === Qt.LeftButton && !card.isSelected
                                    && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
                                pane.selectRow(card.index, false, false);
                        }
                        onPositionChanged: function(mouse) {
                            if (dragging || !(mouse.buttons & (Qt.LeftButton | Qt.RightButton)) || pane.renamingPath === card.path)
                                return;
                            // Archive members aren't real files; trashed
                            // files must be restored, not dragged out.
                            if (paneEngine.location_kind === "archive" || paneEngine.location_kind === "trash")
                                return;
                            var dx = mouse.x - pressPt.x, dy = mouse.y - pressPt.y;
                            if (dx * dx + dy * dy >= 36) {
                                dragging = true;
                                if (!card.isSelected)
                                    pane.selectRow(card.index, false, false);
                                dragManager.isRmb = !!(mouse.buttons & Qt.RightButton);
                                dragManager.cursorPos = mapToItem(window.contentItem, mouse.x, mouse.y);
                                dragManager.begin(pane.selectedPaths(), mouse);
                            }
                        }
                        onReleased: if (dragging) { dragManager.end(); dragging = false; }
                        onCanceled: if (dragging) { dragManager.end(); dragging = false; }
                        onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton) {
                                if (!card.isSelected)
                                    pane.selectRow(card.index, false, false);
                                var pt = mapToItem(window.contentItem, mouse.x, mouse.y);
                                window.openItemMenu(pane, card.index, pt.x, pt.y);
                            } else {
                                contextMenu.close();
                                var wasOnlySelected = card.isSelected && pane.selectedCount === 1;
                                pane.selectRow(card.index, !!(mouse.modifiers & Qt.ControlModifier), !!(mouse.modifiers & Qt.ShiftModifier));
                                // Single click on the already selected name renames (like Nautilus).
                                if (wasOnlySelected && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier))
                                        && theme.clickToRename && mouse.y > card.height * 0.6)
                                    renameDelay.restart();
                            }
                        }
                        onDoubleClicked: function(mouse) {
                            renameDelay.stop();
                            if (mouse.button === Qt.LeftButton)
                                pane.openRow(card.index);
                        }
                        Timer { id: renameDelay; interval: 500; onTriggered: pane.startRename() }
                    }
                }
            }

            // ===================== LIST =====================
            Rectangle {
                id: listHeader
                visible: pane.isList()
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                height: 32
                radius: theme.radiusM
                color: theme.surfaceContainer
                z: 2

                RowLayout {
                    anchors.fill: parent
                    anchors.leftMargin: 16
                    anchors.rightMargin: 16
                    spacing: 12

                    Repeater {
                        model: [
                            { key: "name", label: qsTr("Name"), fill: true, width: 100, show: true, defaultAsc: true },
                            { key: "modified", label: qsTr("Date Modified"), fill: false, width: 150, show: pane.width >= 560, defaultAsc: false },
                            { key: "type", label: qsTr("Type"), fill: false, width: 100, show: pane.width >= 720, defaultAsc: true },
                            { key: "size", label: qsTr("Size"), fill: false, width: 80, show: pane.width >= 640, defaultAsc: false }
                        ]
                        delegate: Item {
                            visible: modelData.show
                            Layout.fillWidth: modelData.fill
                            Layout.preferredWidth: modelData.width
                            Layout.minimumWidth: modelData.fill ? 100 : 60
                            Layout.fillHeight: true

                            RowLayout {
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 6
                                Text {
                                    text: modelData.label
                                    color: paneEngine.sort_by === modelData.key ? theme.primary : theme.textMuted
                                    font.pixelSize: theme.fs(11)
                                    font.bold: true
                                }
                                LoafIcon {
                                    visible: paneEngine.sort_by === modelData.key
                                    name: paneEngine.sort_ascending ? "sort-ascending" : "sort-descending"
                                    size: 13
                                    color: theme.primary
                                }
                            }
                            MouseArea {
                                anchors.fill: parent
                                cursorShape: Qt.PointingHandCursor
                                Accessible.role: Accessible.ColumnHeader
                                Accessible.name: modelData.label
                                onClicked: {
                                    if (paneEngine.sort_by === modelData.key)
                                        paneEngine.toggle_sort_order();
                                    else
                                        paneEngine.set_sort(modelData.key, modelData.defaultAsc);
                                }
                            }
                        }
                    }
                }
            }

            ListView {
                id: listView
                visible: pane.isList()
                enabled: visible
                anchors.top: listHeader.bottom
                anchors.topMargin: 6
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: 3
                clip: true
                cacheBuffer: theme.lowPower ? 0 : 400
                boundsBehavior: Flickable.StopAtBounds
                model: visible ? paneEngine : null
                Accessible.role: Accessible.List
                Accessible.name: paneEngine.current_dir_name

                add: Transition {
                    enabled: theme.animate
                    NumberAnimation { property: "opacity"; from: 0.0; to: 1.0; duration: 180; easing.type: Easing.OutCubic }
                }
                displaced: Transition {
                    enabled: theme.animate
                    NumberAnimation { property: "y"; duration: 200; easing.type: Easing.OutCubic }
                }

                ScrollBar.vertical: ScrollBar {
                    id: listScroll
                    policy: ScrollBar.AsNeeded
                    width: 12
                    padding: 2
                    contentItem: Rectangle {
                        implicitWidth: 6
                        radius: 3
                        color: listScroll.pressed ? theme.primary : (listScroll.hovered ? theme.outline : theme.outlineVariant)
                        opacity: listScroll.active ? 1.0 : 0.0
                        Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: 200 } }
                    }
                }

                WheelHandler {
                    target: null
                    acceptedModifiers: Qt.ControlModifier
                    onWheel: function(event) { theme.stepZoom(event.angleDelta.y > 0 ? 1 : -1); }
                }

                // Empty space below the rows: deselect / background menu.
                footer: Item {
                    width: listView.width
                    height: Math.max(40, listView.height - listView.contentHeight + 40)
                    MouseArea {
                        anchors.fill: parent
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        onPressed: { pane.activated(); window.defocusInputs(); }
                        onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton) {
                                var pt = mapToItem(window.contentItem, mouse.x, mouse.y);
                                window.openEmptyMenu(pane, pt.x, pt.y);
                            } else {
                                pane.clearSelection();
                            }
                        }
                    }
                }

                delegate: Item {
                    id: row
                    width: listView.width
                    height: Math.round(38 * Math.max(0.85, Math.min(1.3, pane.zoom)))

                    required property int index
                    required property string name
                    required property string path
                    required property bool is_dir
                    required property bool is_symlink
                    required property string icon
                    required property string system_icon
                    required property string category
                    required property string size_str
                    required property string modified_str
                    required property bool thumbable
                    required property string thumb_id
                    required property string detail
                    required property string display_name
                    required property bool starred

                    readonly property bool isSelected: !!pane.selection[path]
                    readonly property bool isCut: !!window.cutSet[path]
                    readonly property bool isDropTarget: listDrop.containsDrag
                    readonly property bool hasThumb: theme.showThumbnails && thumbable && listThumb.status === Image.Ready
                    readonly property bool isCursor: window.keyboardNavActive && pane.isActive && pane.cursorPath === path

                    Accessible.role: Accessible.ListItem
                    Accessible.name: name
                    Accessible.selected: isSelected

                    opacity: isCut ? 0.5 : 1.0

                    Rectangle {
                        anchors.fill: parent
                        radius: theme.radiusM
                        color: row.isSelected ? theme.secondaryContainer : (row.isDropTarget ? theme.primaryContainer : theme.hoverOverlay)
                        opacity: (row.isSelected || rowMouse.containsMouse || row.isDropTarget) ? 1.0 : 0.0
                        border.color: row.isCursor ? theme.primary : "transparent"
                        border.width: row.isCursor ? 2 : 0
                        Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: theme.durationFast } }
                    }

                    RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: 12
                        anchors.rightMargin: 12
                        spacing: 12

                        RowLayout {
                            Layout.fillWidth: true
                            spacing: 10

                            Item {
                                width: 22; height: 22
                                Layout.alignment: Qt.AlignVCenter

                                LoafIcon {
                                    visible: !row.hasThumb && theme.iconSource === "phosphor"
                                    anchors.centerIn: parent
                                    name: row.isCut ? (row.is_dir ? "folder-dashed" : "file-dashed") : (row.icon || "file")
                                    size: 18
                                    color: row.isSelected ? theme.secondaryContainerFg : (row.is_dir ? theme.primary : theme.textMain)
                                }
                                Image {
                                    visible: !row.hasThumb && theme.iconSource !== "phosphor"
                                    anchors.centerIn: parent
                                    source: theme.iconSource !== "phosphor" ? window.systemIcon(row.system_icon) : ""
                                    width: 18; height: 18
                                    sourceSize.width: 36; sourceSize.height: 36
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                }
                                Rectangle {
                                    anchors.fill: parent
                                    visible: row.hasThumb
                                    radius: 6
                                    color: theme.surfaceContainerHigh
                                    clip: true
                                    Image {
                                        id: listThumb
                                        anchors.fill: parent
                                        source: theme.showThumbnails && row.thumbable && row.thumb_id.length > 0 ? ("image://thumb/" + row.thumb_id) : ""
                                        fillMode: Image.PreserveAspectCrop
                                        sourceSize.width: 24; sourceSize.height: 24
                                        asynchronous: true
                                    }
                                }
                                Rectangle {
                                    visible: row.is_symlink
                                    width: 10; height: 10; radius: 5
                                    color: theme.surfaceContainer
                                    border.color: theme.outlineVariant
                                    border.width: 1
                                    anchors.bottom: parent.bottom
                                    anchors.right: parent.right
                                    LoafIcon { anchors.centerIn: parent; name: "arrow-square-out"; size: 7; color: theme.primary }
                                }
                            }

                            Loader {
                                Layout.fillWidth: true
                                Layout.preferredHeight: 26
                                sourceComponent: pane.renamingPath === row.path ? listRename : listName
                                Component {
                                    id: listName
                                    ColumnLayout {
                                        spacing: 0
                                        Text {
                                            Layout.fillWidth: true
                                            text: paneEngine.is_searching_everywhere ? (row.display_name || row.name) : row.name
                                            color: row.isSelected ? theme.secondaryContainerFg : theme.textMain
                                            font.pixelSize: theme.fs(13)
                                            font.bold: row.is_dir || row.isSelected
                                            elide: Text.ElideMiddle
                                            verticalAlignment: Text.AlignVCenter
                                        }
                                        Text {
                                            // Where search / recent / trash items live.
                                            visible: row.detail.length > 0
                                            Layout.fillWidth: true
                                            text: row.detail
                                            color: theme.textMuted
                                            font.pixelSize: theme.fs(10)
                                            elide: Text.ElideMiddle
                                        }
                                    }
                                }
                                Component {
                                    id: listRename
                                    InlineRename {
                                        originalName: row.name
                                        isDir: row.is_dir
                                        horizontal: true
                                        onCommit: function(text) { pane.commitRename(row.path, text); }
                                        onCancel: pane.cancelRename()
                                    }
                                }
                            }

                            LoafIcon {
                                visible: row.starred
                                name: "star"
                                size: 13
                                color: theme.primary
                            }
                        }

                        Text {
                            visible: pane.width >= 560
                            Layout.preferredWidth: 150
                            Layout.minimumWidth: 96
                            text: row.modified_str
                            color: row.isSelected ? theme.secondaryContainerFg : theme.textMuted
                            font.pixelSize: theme.fs(11)
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: pane.width >= 720
                            Layout.preferredWidth: 100
                            Layout.minimumWidth: 70
                            text: row.category
                            color: row.isSelected ? theme.secondaryContainerFg : theme.outline
                            font.pixelSize: theme.fs(11)
                            elide: Text.ElideRight
                        }
                        Text {
                            visible: pane.width >= 640
                            Layout.preferredWidth: 80
                            Layout.minimumWidth: 60
                            text: row.size_str
                            color: row.isSelected ? theme.secondaryContainerFg : theme.textMuted
                            font.pixelSize: theme.fs(11)
                            elide: Text.ElideRight
                        }
                    }

                    DropArea {
                        id: listDrop
                        anchors.fill: parent
                        enabled: row.is_dir && !paneEngine.read_only
                        keys: ["text/uri-list"]
                        onEntered: dragManager.hover(row.path, paneEngine)
                        onExited: if (dragManager.hoverTarget === row.path) dragManager.hoverTarget = ""
                        onDropped: function(drop) { pane.handleDropOn(drop, row.path, row); }
                    }

                    MouseArea {
                        id: rowMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        acceptedButtons: Qt.LeftButton | Qt.RightButton
                        cursorShape: Qt.PointingHandCursor
                        preventStealing: true
                        onWheel: function(wheel) { wheel.accepted = false; }

                        property point pressPt
                        property bool dragging: false

                        onPressed: function(mouse) {
                            pane.activated();
                            window.defocusInputs();
                            pressPt = Qt.point(mouse.x, mouse.y);
                            dragging = false;
                            if (mouse.button === Qt.LeftButton && !row.isSelected
                                    && !(mouse.modifiers & (Qt.ControlModifier | Qt.ShiftModifier)))
                                pane.selectRow(row.index, false, false);
                        }
                        onPositionChanged: function(mouse) {
                            if (dragging || !(mouse.buttons & (Qt.LeftButton | Qt.RightButton)) || pane.renamingPath === row.path)
                                return;
                            // Archive members aren't real files; trashed
                            // files must be restored, not dragged out.
                            if (paneEngine.location_kind === "archive" || paneEngine.location_kind === "trash")
                                return;
                            var dx = mouse.x - pressPt.x, dy = mouse.y - pressPt.y;
                            if (dx * dx + dy * dy >= 36) {
                                dragging = true;
                                if (!row.isSelected)
                                    pane.selectRow(row.index, false, false);
                                dragManager.isRmb = !!(mouse.buttons & Qt.RightButton);
                                dragManager.cursorPos = mapToItem(window.contentItem, mouse.x, mouse.y);
                                dragManager.begin(pane.selectedPaths(), mouse);
                            }
                        }
                        onReleased: if (dragging) { dragManager.end(); dragging = false; }
                        onCanceled: if (dragging) { dragManager.end(); dragging = false; }
                        onClicked: function(mouse) {
                            if (mouse.button === Qt.RightButton) {
                                if (!row.isSelected)
                                    pane.selectRow(row.index, false, false);
                                var pt = mapToItem(window.contentItem, mouse.x, mouse.y);
                                window.openItemMenu(pane, row.index, pt.x, pt.y);
                            } else {
                                contextMenu.close();
                                pane.selectRow(row.index, !!(mouse.modifiers & Qt.ControlModifier), !!(mouse.modifiers & Qt.ShiftModifier));
                            }
                        }
                        onDoubleClicked: function(mouse) {
                            if (mouse.button === Qt.LeftButton)
                                pane.openRow(row.index);
                        }
                    }
                }
            }
        }
    }
}
