import QtQuick

Rectangle {
    required property var app

    anchors.fill: parent
    z: 40
    visible: !!app.confirmChange
    color: "white"
    MouseArea {
        anchors.fill: parent
    }
    Column {
        anchors.centerIn: parent
        width: parent.width - 64
        spacing: 24
        Text {
            width: parent.width
            text: app.confirmChange && app.confirmChange.operation === "discard" ? "Discard local change?" : "Delete event?"
            wrapMode: Text.Wrap
            font.pixelSize: 36
            font.bold: true
            color: "black"
        }
        Text {
            width: parent.width
            text: app.confirmChange ? app.confirmChange.title : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 30
            color: "black"
        }
        Text {
            width: parent.width
            text: app.confirmChange && app.confirmChange.operation === "discard" ? "This removes the queued change from the tablet. It does not undo a change already accepted by Google. Sync afterward to get the current Google version." : "Google deletion will be queued until it can sync. A local-only event is deleted from this tablet."
            wrapMode: Text.Wrap
            font.pixelSize: 24
            color: "black"
        }
        Text {
            visible: !!app.editMessage
            width: parent.width
            text: app.editMessage
            wrapMode: Text.Wrap
            font.pixelSize: 22
            color: "black"
        }
        Row {
            spacing: 20
            SettingsAction {
                label: "Cancel"
                enabled: !app.changeBusy
                onTriggered: app.confirmChange = null
            }
            SettingsAction {
                width: 180
                label: app.changeBusy ? "Saving…" : (app.confirmChange && app.confirmChange.operation === "discard" ? "Discard" : "Delete")
                enabled: !app.changeBusy && !app.syncBusy
                onTriggered: app.submitChange({
                    operation: app.confirmChange.operation,
                    id: app.confirmChange.id
                })
            }
        }
    }
}
