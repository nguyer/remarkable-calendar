import QtQuick

Rectangle {
    id: settingsPage
    required property var app
    anchors.fill: parent
    z: 10
    visible: app.settingsOpen
    color: "white"
    MouseArea {
        anchors.fill: parent
    }
    Item {
        id: settingsHeader
        width: parent.width
        height: app.toolbarHeight
        ToolbarButton {
            y: 12
            icon: "previous"
            label: "Close settings"
            onTriggered: {
                app.closeSettings();
            }
        }
        ToolbarTitle {
            anchors.centerIn: parent
            text: "Calendars & sync"
        }
        Rectangle {
            anchors.bottom: parent.bottom
            width: parent.width
            height: 2
            color: "black"
        }
    }
    Column {
        id: settingsControls
        anchors.top: settingsHeader.bottom
        x: 18
        width: parent.width - 36
        spacing: 14
        Text {
            width: parent.width
            text: app.settingsMessage
            wrapMode: Text.Wrap
            font.pixelSize: 20
            color: "black"
        }
        Text {
            text: app.settingsDraft ? "Display timezone: " + app.settingsDraft.timezone : ""
            font.pixelSize: 20
            color: "black"
        }
        Row {
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Time format"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                label: app.settingsDraft && app.settingsDraft.time_format === "24h" ? "24-hour" : "12-hour"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("time_format", app.settingsDraft.time_format === "24h" ? "12h" : "24h")
            }
        }
        Row {
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Day view"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 240
                label: app.settingsDraft && app.settingsDraft.day_scroll ? "24-hour scroll" : "Fixed hours"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("day_scroll", !app.settingsDraft.day_scroll)
            }
        }
        Row {
            visible: !!app.settingsDraft && !app.settingsDraft.day_scroll
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Day starts"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "−"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("day_start", Math.max(0, app.settingsDraft.day_start - 60))
            }
            Text {
                width: 130
                height: 54
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: app.settingsDraft ? app.formatTime(app.minuteTime(app.settingsDraft.day_start), app.settingsDraft) : ""
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "+"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("day_start", Math.min(app.settingsDraft.day_end - 60, app.settingsDraft.day_start + 60))
            }
        }
        Row {
            visible: !!app.settingsDraft && !app.settingsDraft.day_scroll
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Day ends"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "−"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("day_end", Math.max(app.settingsDraft.day_start + 60, app.settingsDraft.day_end - 60))
            }
            Text {
                width: 130
                height: 54
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: app.settingsDraft ? app.formatTime(app.minuteTime(app.settingsDraft.day_end), app.settingsDraft) : ""
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "+"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("day_end", Math.min(1440, app.settingsDraft.day_end + 60))
            }
        }
        Row {
            width: parent.width
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Months back"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "−"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("months_before", Math.max(0, app.settingsDraft.months_before - 1))
            }
            Text {
                width: 60
                height: 54
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: app.settingsDraft ? app.settingsDraft.months_before : ""
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "+"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("months_before", Math.min(12, app.settingsDraft.months_before + 1))
            }
        }
        Row {
            width: parent.width
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Months ahead"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "−"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("months_after", Math.max(1, app.settingsDraft.months_after - 1))
            }
            Text {
                width: 60
                height: 54
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
                text: app.settingsDraft ? app.settingsDraft.months_after : ""
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                width: 60
                label: "+"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("months_after", Math.min(18, app.settingsDraft.months_after + 1))
            }
        }
        Row {
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Refresh on launch"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                label: app.settingsDraft && app.settingsDraft.auto_sync ? "On" : "Off"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.changeSetting("auto_sync", !app.settingsDraft.auto_sync)
            }
        }
        Row {
            spacing: 12
            Text {
                width: 240
                height: 54
                verticalAlignment: Text.AlignVCenter
                text: "Refresh if older than"
                font.pixelSize: 23
                color: "black"
            }
            SettingsAction {
                label: app.settingsDraft ? app.settingsDraft.stale_minutes + " min" : ""
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: {
                    var choices = [15, 60, 360, 1440];
                    app.changeSetting("stale_minutes", choices[(choices.indexOf(app.settingsDraft.stale_minutes) + 1) % choices.length]);
                }
            }
        }
        Row {
            spacing: 16
            SettingsAction {
                width: 180
                label: "Refresh list"
                enabled: !app.syncBusy && !app.settingsLoading && !app.settingsDirty
                onTriggered: app.requestSync(true, true)
            }
            SettingsAction {
                width: 180
                label: "Save & sync"
                enabled: !!app.settingsDraft && !app.settingsLoading && !app.syncBusy
                onTriggered: app.saveSettings()
            }
        }
        Text {
            width: parent.width
            text: (app.settingsDirty ? "Unsaved changes · Save & sync to apply. Back discards changes." : app.syncMessage) + "\n" + app.backendStatus
            wrapMode: Text.Wrap
            font.pixelSize: 18
            color: "black"
        }
        Rectangle {
            width: parent.width
            height: 2
            color: "black"
        }
    }
    Flickable {
        anchors.top: settingsControls.bottom
        anchors.topMargin: 12
        anchors.bottom: parent.bottom
        x: 18
        width: parent.width - 36
        clip: true
        contentHeight: calendarRows.height
        Column {
            id: calendarRows
            width: parent.width
            Text {
                visible: app.pendingChanges.length > 0
                text: "Pending changes"
                font.pixelSize: 25
                font.bold: true
                color: "black"
                bottomPadding: 12
            }
            Repeater {
                model: app.pendingChanges
                delegate: Item {
                    required property var modelData
                    width: calendarRows.width
                    height: pendingLabel.height + 80
                    Text {
                        id: pendingLabel
                        width: parent.width
                        text: modelData.operation + ": " + modelData.title + (modelData.error ? "\n" + modelData.error : "")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: 21
                        color: "black"
                    }
                    SettingsAction {
                        y: pendingLabel.height + 8
                        width: 160
                        label: "Discard"
                        enabled: !app.syncBusy
                        onTriggered: {
                            app.editMessage = "";
                            app.confirmChange = {
                                operation: "discard",
                                id: modelData.id,
                                title: modelData.title
                            };
                        }
                    }
                }
            }
            Repeater {
                model: app.calendarOptions
                delegate: Item {
                    required property var modelData
                    width: calendarRows.width
                    height: Math.max(74, calendarName.implicitHeight + 24)
                    Rectangle {
                        x: 0
                        y: 20
                        width: 26
                        height: 26
                        border.width: 2
                        border.color: "black"
                        color: modelData.enabled ? "black" : "white"
                    }
                    Rectangle {
                        x: 42
                        y: 20
                        width: 14
                        height: 30
                        color: modelData.color
                    }
                    Text {
                        id: calendarName
                        x: 72
                        y: 16
                        width: parent.width - 80
                        text: modelData.name + (modelData.available ? "" : " (unavailable)")
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: 24
                        font.bold: modelData.enabled
                        color: "black"
                    }
                    MouseArea {
                        anchors.fill: parent
                        enabled: !app.settingsLoading && !app.syncBusy && (modelData.available || modelData.enabled)
                        onClicked: app.toggleCalendar(modelData.id)
                    }
                }
            }
        }
    }
}
