import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import app.loaf

// Navigation rail: This PC, Recent, Starred, the user's (localized) folders,
// GTK bookmarks and Trash, from core.places_json. Scrolls when the window is
// short, accepts drops, and every entry has a context menu.
Rectangle {
    id: rail

    property bool expanded: false
    // Id of the highlighted entry ("pc", "settings", "home", "bookmark:/x", ...).
    property string activeId: ""

    signal placeClicked(var place, bool newTab)
    signal settingsClicked()
    signal placeMenuRequested(var place, real x, real y)

    readonly property var places: {
        try {
            return JSON.parse(core.places_json || "[]");
        } catch (e) {
            return [];
        }
    }

    readonly property var trashPlace: {
        for (var i = 0; i < places.length; ++i) {
            if (places[i].id === "trash") return places[i];
        }
        return { id: "trash", kind: "trash", name: qsTr("Trash"), path: "trash:///", icon: "trash", system_icon: "user-trash-symbolic" };
    }

    readonly property bool showTrash: !theme.hideTrashWhenEmpty || (typeof core !== "undefined" && core && !core.trash_empty) || (typeof dragManager !== "undefined" && dragManager && dragManager.active)

    radius: theme.radiusXl
    color: theme.surfaceContainer
    clip: true
    implicitWidth: expanded ? 200 : 68
    Behavior on implicitWidth { enabled: theme.animate; NumberAnimation { duration: 230; easing.type: Easing.OutCubic } }

    Accessible.role: Accessible.Pane
    Accessible.name: qsTr("Sidebar")

    ColumnLayout {
        anchors.fill: parent
        anchors.topMargin: 14
        anchors.bottomMargin: 14
        spacing: 8

        // Expand / collapse toggle (restored from before PR #24)
        Item {
            Layout.fillWidth: true
            Layout.preferredHeight: 44
            height: 44

            Rectangle {
                width: 44
                height: 44
                radius: 22
                x: 12
                color: toggleMouse.containsMouse ? theme.surfaceContainerHigh : "transparent"
                Behavior on color { enabled: theme.animate; ColorAnimation { duration: theme.durationFast } }

                LoafIcon {
                    anchors.centerIn: parent
                    name: rail.expanded ? "sidebar" : "sidebar-simple"
                    size: 20
                    color: theme.textMain
                }

                MouseArea {
                    id: toggleMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: rail.expanded = !rail.expanded
                }
            }
        }

        ListView {
            id: placeList
            Layout.fillWidth: true
            Layout.fillHeight: true
            clip: true
            spacing: 6
            boundsBehavior: Flickable.StopAtBounds
            model: rail.places.filter(function(p) { return p.id !== "trash"; })
            ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded; width: 6 }

            delegate: RailButton {
                width: placeList.width
                required property var modelData
                required property int index
                iconName: modelData.icon
                systemIcon: modelData.system_icon
                label: modelData.name
                showLabel: rail.expanded
                selected: rail.activeId === modelData.id
                dimmed: modelData.missing === true
                dropPath: (modelData.kind === "place" || modelData.kind === "bookmark") ? modelData.path : ""
                accessibleName: modelData.name
                onClicked: rail.placeClicked(modelData, false)
                onMiddleClicked: rail.placeClicked(modelData, true)
                onMenuRequested: function(x, y) { rail.placeMenuRequested(modelData, x, y); }
                onFilesDropped: function(paths, asCopy) {
                    if (modelData.kind === "trash")
                        core.trash_items(JSON.stringify(paths));
                    else if (dropPath.length > 0)
                        window.handleDrop(paths, dropPath, asCopy);
                }
                acceptsTrashDrop: modelData.kind === "trash"
            }

            // Drop a folder on the empty part of the rail to bookmark it.
            footer: Item {
                width: placeList.width
                height: Math.max(24, placeList.height - placeList.contentHeight + 0)
                DropArea {
                    anchors.fill: parent
                    keys: ["text/uri-list"]
                    onDropped: function(drop) {
                        var paths = window.urlsToPaths(drop.urls);
                        for (var i = 0; i < paths.length; ++i)
                            core.add_bookmark(paths[i]);
                        drop.accept(Qt.LinkAction);
                    }
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 8
                        radius: theme.radiusL
                        color: "transparent"
                        border.width: parent.containsDrag ? 2 : 0
                        border.color: theme.primary
                        Text {
                            visible: parent.parent.containsDrag && rail.expanded
                            anchors.centerIn: parent
                            text: qsTr("Add to sidebar")
                            color: theme.primary
                            font.pixelSize: theme.fs(11)
                        }
                    }
                }
            }
        }

        // Animated Pinned Trash right above Settings
        Item {
            id: trashContainer
            Layout.fillWidth: true
            visible: height > 0.01
            clip: true
            height: rail.showTrash ? 44 : 0
            opacity: rail.showTrash ? 1.0 : 0.0

            Behavior on height { enabled: theme.animate; SpringAnimation { spring: 3.5; damping: 0.35 } }
            Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }

            RailButton {
                id: trashButton
                anchors.fill: parent
                iconName: "trash"
                systemIcon: "user-trash-symbolic"
                label: qsTr("Trash")
                showLabel: rail.expanded
                selected: rail.activeId === "trash"
                accessibleName: qsTr("Trash")
                acceptsTrashDrop: true
                onClicked: rail.placeClicked(rail.trashPlace, false)
                onMiddleClicked: rail.placeClicked(rail.trashPlace, true)
                onMenuRequested: function(x, y) { rail.placeMenuRequested(rail.trashPlace, x, y); }
                onFilesDropped: function(paths, asCopy) {
                    core.trash_items(JSON.stringify(paths));
                }
            }
        }

        RailButton {
            Layout.fillWidth: true
            iconName: "gear"
            systemIcon: "preferences-system-symbolic"
            label: qsTr("Settings")
            showLabel: rail.expanded
            selected: rail.activeId === "settings"
            accessibleName: qsTr("Settings")
            onClicked: rail.settingsClicked()
        }
    }

    // One row of the rail (icon + optional label).
    component RailButton: Item {
        id: btn
        property string iconName: "folder"
        property string systemIcon: ""
        property string label: ""
        property bool showLabel: false
        property bool selected: false
        property bool dimmed: false
        property string dropPath: ""
        property bool acceptsTrashDrop: false
        property string accessibleName: label

        signal clicked()
        signal middleClicked()
        signal menuRequested(real x, real y)
        signal filesDropped(var paths, bool asCopy)

        implicitHeight: 44
        height: 44
        Accessible.role: Accessible.Button
        Accessible.name: accessibleName
        Accessible.onPressAction: btn.clicked()

        readonly property bool dropHover: drop.containsDrag

        Rectangle {
            x: 12
            width: btn.showLabel ? btn.width - 24 : 44
            height: 44
            radius: 22
            color: btn.dropHover ? theme.primaryContainer
                : (btn.selected ? theme.primaryContainer : (mouse.containsMouse ? theme.hoverOverlay : "transparent"))
            border.width: btn.dropHover ? 2 : 0
            border.color: theme.primary
            Behavior on color { enabled: theme.animate; ColorAnimation { duration: theme.durationFast } }
            Behavior on width { enabled: theme.animate; SpringAnimation { spring: 3.5; damping: 0.35 } }
        }

        Item {
            id: iconBox
            x: 12
            width: 44
            height: 44
            opacity: btn.dimmed ? 0.45 : 1.0
            scale: mouse.pressed ? 0.88 : (mouse.containsMouse ? 1.10 : 1.0)
            Behavior on scale { enabled: theme.animate; SpringAnimation { spring: 4.5; damping: 0.3 } }

            LoafIcon {
                visible: theme.iconSource === "phosphor" || btn.systemIcon.length === 0
                anchors.centerIn: parent
                name: btn.iconName
                size: 20
                color: btn.selected ? theme.primaryContainerFg : (mouse.containsMouse ? theme.textMain : theme.textMuted)
            }
            Image {
                visible: theme.iconSource !== "phosphor" && btn.systemIcon.length > 0
                anchors.centerIn: parent
                source: visible ? window.systemIcon(btn.systemIcon) : ""
                width: 20
                height: 20
                sourceSize.width: 40
                sourceSize.height: 40
                fillMode: Image.PreserveAspectFit
            }
        }

        Text {
            anchors.left: iconBox.right
            anchors.leftMargin: 6
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: opacity > 0.01
            opacity: btn.showLabel ? (btn.dimmed ? 0.5 : 1.0) : 0.0
            scale: btn.showLabel ? 1.0 : 0.4
            transformOrigin: Item.Left
            transform: Translate {
                x: btn.showLabel ? 0 : -14
                Behavior on x { enabled: theme.animate; SpringAnimation { spring: 3.5; damping: 0.35 } }
            }
            Behavior on opacity { enabled: theme.animate; NumberAnimation { duration: 160 } }
            Behavior on scale { enabled: theme.animate; SpringAnimation { spring: 3.5; damping: 0.35 } }
            text: btn.label
            color: btn.selected ? theme.primaryContainerFg : (mouse.containsMouse ? theme.textMain : theme.textMuted)
            font.pixelSize: theme.fs(13)
            font.bold: btn.selected
            elide: Text.ElideRight
        }

        ToolTip.visible: !btn.showLabel && mouse.containsMouse && btn.label.length > 0
        ToolTip.text: btn.label
        ToolTip.delay: 500

        DropArea {
            id: drop
            anchors.fill: parent
            enabled: btn.dropPath.length > 0 || btn.acceptsTrashDrop
            keys: ["text/uri-list"]
            onDropped: function(d) {
                var paths = window.urlsToPaths(d.urls);
                if (paths.length === 0)
                    return;
                var asCopy = (d.source === dragProxy) ? dragManager.asCopy : (d.proposedAction === Qt.CopyAction);
                d.accept(asCopy ? Qt.CopyAction : Qt.MoveAction);
                btn.filesDropped(paths, asCopy);
            }
        }

        MouseArea {
            id: mouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
            onClicked: function(m) {
                if (m.button === Qt.RightButton) {
                    var p = mapToItem(window.contentItem, m.x, m.y);
                    btn.menuRequested(p.x, p.y);
                } else if (m.button === Qt.MiddleButton) {
                    btn.middleClicked();
                } else {
                    btn.clicked();
                }
            }
        }
    }
}
