import QtQuick

Rectangle {
    id: editorPage
    required property var app
    property alias keyboardInput: keyboardInput
    anchors.fill: parent
    z: 30
    visible: app.editOpen
    color: "white"
    component EditField: Item {
        property string field
        property string label
        width: parent.width
        height: 90
        Text {
            text: parent.label
            font.pixelSize: 21
            font.bold: true
            color: "black"
        }
        Rectangle {
            y: 30
            width: parent.width
            height: 56
            color: "white"
            border.color: "black"
            border.width: app.editField === parent.field ? 3 : 1
            Text {
                x: 10
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width - 20
                text: app.editDraft ? String(app.editDraft[parent.parent.field] || "") : ""
                textFormat: Text.PlainText
                elide: Text.ElideRight
                font.pixelSize: 25
                color: "black"
            }
            MouseArea {
                anchors.fill: parent
                enabled: !app.changeBusy
                onClicked: {
                    app.editField = parent.parent.field;
                    app.keyboardSymbols = parent.parent.field.indexOf("day") >= 0 || parent.parent.field.indexOf("time") >= 0;
                    keyboardInput.forceActiveFocus();
                }
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        onClicked: app.hideEditKeyboard()
    }
    Item {
        id: editHeader
        width: parent.width
        height: app.toolbarHeight
        ToolbarButton {
            y: 12
            icon: "save"
            label: "Save on tablet"
            enabled: !app.changeBusy && !app.syncBusy && !app.settingsLoading && !!app.editDraft && !!app.editDraft.id
            onTriggered: app.saveEdit()
        }
        ToolbarTitle {
            anchors.centerIn: parent
            text: app.editDraft && app.editDraft.operation === "create" ? "New event" : "Edit event"
        }
        ToolbarButton {
            y: 12
            anchors.right: parent.right
            icon: "close"
            label: "Cancel editing"
            enabled: !app.changeBusy
            onTriggered: {
                app.hideEditKeyboard();
                app.editOpen = false;
            }
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 2
            color: "black"
        }
    }
    Flickable {
        id: editForm
        anchors.top: editHeader.bottom
        anchors.bottom: editKeyboard.visible ? editKeyboard.top : parent.bottom
        x: 18
        width: parent.width - 36
        clip: true
        contentHeight: editFields.height + 24
        MouseArea {
            width: editForm.width
            height: Math.max(editForm.height, editFields.height + 24)
            onClicked: app.hideEditKeyboard()
        }
        Column {
            id: editFields
            y: 12
            width: parent.width
            spacing: 12
            Text {
                width: parent.width
                text: app.editMessage
                visible: !!app.editMessage
                wrapMode: Text.Wrap
                font.pixelSize: 21
                color: "black"
            }
            Text {
                width: parent.width
                text: "Changes are saved on this tablet first. Google changes sync when connected."
                wrapMode: Text.Wrap
                font.pixelSize: 20
                color: "black"
            }
            Text {
                visible: !!app.activeDetailEvent && !!app.activeDetailEvent.details && app.activeDetailEvent.details.recurring && app.editDraft && app.editDraft.operation === "update"
                width: parent.width
                text: "Recurring event · only this occurrence will change."
                wrapMode: Text.Wrap
                font.pixelSize: 21
                font.bold: true
                color: "black"
            }
            SettingsAction {
                width: parent.width
                label: app.editCalendarName()
                enabled: !!app.editDraft && app.editDraft.operation === "create" && !app.changeBusy && !app.settingsLoading
                onTriggered: app.cycleEditCalendar()
            }
            EditField {
                field: "title"
                label: "Title"
            }
            SettingsAction {
                label: app.editDraft && app.editDraft.all_day ? "All day: On" : "All day: Off"
                width: 180
                enabled: !app.changeBusy
                onTriggered: {
                    app.hideEditKeyboard();
                    var value = !app.editDraft.all_day;
                    app.setEditField("all_day", value);
                    if (!value && app.editDraft.start_time === "00:00" && app.editDraft.end_time === "00:00") {
                        app.setEditField("start_time", "09:00");
                        app.setEditField("end_time", "10:00");
                    }
                }
            }
            EditField {
                field: "start_day"
                label: "Start date · YYYY-MM-DD"
            }
            EditField {
                field: "start_time"
                label: "Start time · HH:MM (24-hour entry)"
                visible: !!app.editDraft && !app.editDraft.all_day
            }
            EditField {
                field: "end_day"
                label: "End date · YYYY-MM-DD (last included day for all-day events)"
            }
            EditField {
                field: "end_time"
                label: "End time · HH:MM (24-hour entry)"
                visible: !!app.editDraft && !app.editDraft.all_day
            }
            EditField {
                field: "location"
                label: "Location"
            }
            EditField {
                field: "description"
                label: "Description"
            }
        }
    }
    Rectangle {
        id: editKeyboard
        anchors.bottom: parent.bottom
        width: parent.width
        height: keyboardRows.height + 16
        visible: app.editOpen && !!app.editField
        color: "white"
        border.color: "black"
        border.width: 2
        MouseArea {
            anchors.fill: parent
        }
        Column {
            id: keyboardRows
            x: 8
            y: 8
            width: parent.width - 16
            spacing: 5
            Rectangle {
                width: parent.width
                height: 56
                color: "white"
                border.color: "black"
                TextInput {
                    id: keyboardInput
                    x: 10
                    y: 8
                    width: parent.width - 20
                    height: 40
                    font.pixelSize: 28
                    color: "black"
                    clip: true
                    selectByMouse: true
                    text: app.editDraft && app.editField ? String(app.editDraft[app.editField] || "") : ""
                    onTextEdited: app.setEditField(app.editField, text)
                }
            }
            Repeater {
                model: app.keyboardSymbols ? ["1234567890", "-/:.,?!@()", "+=_&%#;[]"] : ["1234567890", "qwertyuiop", "asdfghjkl", "zxcvbnm"]
                delegate: Row {
                    required property string modelData
                    property string keys: modelData
                    width: keyboardRows.width
                    spacing: 4
                    Repeater {
                        model: parent.keys.length
                        delegate: Rectangle {
                            required property int index
                            width: (keyboardRows.width - (parent.keys.length - 1) * 4) / parent.keys.length
                            height: 54
                            color: "white"
                            border.color: "black"
                            property string key: parent.keys.charAt(index)
                            Text {
                                anchors.centerIn: parent
                                text: app.keyboardShift ? parent.key.toUpperCase() : parent.key
                                font.pixelSize: 28
                                color: "black"
                            }
                            MouseArea {
                                anchors.fill: parent
                                onClicked: app.keyboardType(parent.key)
                            }
                        }
                    }
                }
            }
            Row {
                width: parent.width
                spacing: 6
                SettingsAction {
                    width: 90
                    label: app.keyboardShift ? "SHIFT" : "Shift"
                    onTriggered: app.keyboardShift = !app.keyboardShift
                }
                SettingsAction {
                    width: 90
                    label: app.keyboardSymbols ? "ABC" : "#+="
                    onTriggered: app.keyboardSymbols = !app.keyboardSymbols
                }
                SettingsAction {
                    width: keyboardRows.width - 90 * 3 - 100 - 24
                    label: "Space"
                    onTriggered: app.keyboardType(" ")
                }
                SettingsAction {
                    width: 90
                    label: "Del"
                    onTriggered: {
                        var a = keyboardInput.selectionStart;
                        var b = keyboardInput.selectionEnd;
                        if (b > a)
                            keyboardInput.remove(a, b);
                        else if (keyboardInput.cursorPosition > 0)
                            keyboardInput.remove(keyboardInput.cursorPosition - 1, keyboardInput.cursorPosition);
                        app.setEditField(app.editField, keyboardInput.text);
                    }
                }
                SettingsAction {
                    width: 100
                    label: "Done"
                    onTriggered: app.hideEditKeyboard()
                }
            }
        }
    }
}
