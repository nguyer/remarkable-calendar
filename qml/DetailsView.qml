import QtQuick

Rectangle {
    id: detailsPage
    required property var app
    property alias eventScroll: eventView
    anchors.fill: parent
    z: 20
    visible: app.detailsLevel === "event"
    color: "white"
    MouseArea {
        anchors.fill: parent
    }
    Item {
        id: detailsHeader
        width: parent.width
        height: app.toolbarHeight
        ToolbarButton {
            y: 12
            visible: app.detailsLevel === "event"
            icon: "edit"
            label: "Edit event"
            enabled: !app.syncBusy && !!app.activeDetailEvent && !!app.activeDetailEvent.details && app.activeDetailEvent.details.writable
            onTriggered: app.beginEdit(app.activeDetailEvent)
        }
        ToolbarButton {
            x: 64
            y: 12
            visible: app.detailsLevel === "event"
            icon: "delete"
            label: "Delete event"
            enabled: !app.syncBusy && !!app.activeDetailEvent && !!app.activeDetailEvent.details && app.activeDetailEvent.details.writable
            onTriggered: {
                app.editMessage = "";
                app.confirmChange = {
                    operation: "delete",
                    id: app.activeDetailEvent.id,
                    title: app.activeDetailEvent.title
                };
            }
        }
        ToolbarTitle {
            anchors.centerIn: parent
            text: "Event details"
        }
        ToolbarButton {
            y: 12
            visible: app.detailsLevel === "event"
            anchors.right: parent.right
            icon: "close"
            label: "Close event"
            onTriggered: app.closeEvent()
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 2
            color: "black"
        }
    }
    EventView {
        id: eventView
        app: detailsPage.app
        anchors.top: detailsHeader.bottom
        anchors.bottom: parent.bottom
    }
}
