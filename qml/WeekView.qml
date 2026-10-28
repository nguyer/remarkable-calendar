import QtQuick

Item {
    required property var app

    property alias calendar: weekView
    Column {
        id: heading
        height: app.toolbarHeight
        width: parent.width
        Item {
            width: 1
            height: 12
        }
        Item {
            width: parent.width
            height: 70
            ToolbarButton {
                id: previousButton
                anchors.left: parent.left
                icon: "previous"
                label: "Previous week"
                onTriggered: app.shiftWeek(-1)
            }
            ToolbarButton {
                id: dayViewButton
                anchors.left: previousButton.right
                icon: "day"
                label: "Day view"
                onTriggered: app.openToolbarDay()
            }
            ToolbarButton {
                id: todayButton
                anchors.left: dayViewButton.right
                icon: "today"
                label: "Go to today"
                onTriggered: app.selectedDate = new Date()
            }
            ToolbarButton {
                anchors.left: todayButton.right
                icon: "add"
                label: "New event"
                enabled: !app.syncBusy
                onTriggered: app.beginEdit(null)
            }
            ToolbarButton {
                id: settingsButton
                anchors.right: nextButton.left
                icon: "settings"
                label: "Calendar and sync settings"
                onTriggered: {
                    app.settingsOpen = true;
                    app.fetchSettings();
                }
            }
            ToolbarTitle {
                anchors.horizontalCenter: parent.horizontalCenter
                text: Qt.formatDate(app.dayAt(0), "MMM d") + " – " + Qt.formatDate(app.dayAt(6), "MMM d")
            }
            ToolbarButton {
                anchors.right: settingsButton.left
                icon: "sync"
                label: app.syncBusy ? "Sync in progress" : "Sync calendars"
                busy: app.syncBusy
                enabled: !app.syncBusy
                onTriggered: app.requestSync(true)
            }
            ToolbarButton {
                id: nextButton
                anchors.right: parent.right
                icon: "next"
                label: "Next week"
                onTriggered: app.shiftWeek(1)
            }
        }
        Rectangle {
            width: parent.width
            height: 2
            color: "#222222"
        }
    }
    Item {
        id: weekView
        onWidthChanged: app.reflowEvents()
        onHeightChanged: app.reflowEvents()
        anchors.top: heading.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        Column {
            id: dayRows
            width: parent.width
            spacing: 0
            Repeater {
                model: 7
                delegate: Item {
                    id: dayRow
                    required property int index
                    property date day: app.dayAt(index)
                    property bool hasOverflow: app.events.some(function (e) {
                        return e.offset === dayRow.index && e.layoutY + e.layoutHeight > Math.max(0, dayRow.height - 28);
                    })
                    width: dayRows.width
                    height: weekView.height / 7
                    clip: true
                    Rectangle {
                        visible: dayRow.index > 0
                        width: parent.width
                        height: 2
                        color: "#333333"
                    }
                    Row {
                        id: dayContent
                        x: 0
                        y: 0
                        width: parent.width - 10
                        spacing: 6
                        Rectangle {
                            y: dayRow.index > 0 ? 2 : 0
                            width: 80
                            height: dayRow.height - y
                            property bool isToday: app.isoDate(dayRow.day) === app.isoDate(app.todayDate)
                            color: isToday ? "#74d2e8" : "#d9d9d9"
                            Rectangle {
                                anchors.right: parent.right
                                width: 2
                                height: parent.height
                                color: "#000000"
                            }
                            Column {
                                anchors.centerIn: parent
                                spacing: 0
                                Text {
                                    width: 64
                                    horizontalAlignment: Text.AlignHCenter
                                    text: app.days[dayRow.index].toUpperCase()
                                    font.pixelSize: 18
                                    color: parent.parent.isToday ? "#ffffff" : "#000000"
                                }
                                Text {
                                    width: 64
                                    horizontalAlignment: Text.AlignHCenter
                                    text: dayRow.day.getDate()
                                    font.pixelSize: 34
                                    font.bold: true
                                    color: parent.parent.isToday ? "#ffffff" : "#000000"
                                }
                            }
                        }
                        Row {
                            y: 10
                            width: parent.width - 86
                            spacing: 18
                            Repeater {
                                model: 2
                                delegate: Item {
                                    id: periodColumn
                                    required property int index
                                    property real eventLimit: Math.max(0, height)
                                    width: (parent.width - parent.spacing) / 2
                                    height: Math.max(0, dayRow.height - 28)
                                    clip: true
                                    Item {
                                        id: periodEvents
                                        anchors.fill: parent
                                        Repeater {
                                            model: app.events.filter(function (e) {
                                                return e.offset === dayRow.index && e.column === periodColumn.index && e.layoutY + e.layoutHeight <= periodColumn.eventLimit;
                                            })
                                            delegate: CalendarEvent {
                                                required property var modelData
                                                eventData: modelData
                                                width: parent.width
                                                y: modelData.layoutY
                                                visible: y + height <= periodColumn.eventLimit
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Text {
                        visible: dayRow.hasOverflow
                        anchors.right: parent.right
                        anchors.bottom: parent.bottom
                        anchors.rightMargin: 10
                        height: 18
                        verticalAlignment: Text.AlignVCenter
                        text: "More events…"
                        font.pixelSize: 14
                        font.bold: true
                        color: "black"
                    }
                }
            }
        }
        // Use the same touch-to-mouse path as the working toolbar buttons.
        // There is no Flickable to consume the gesture or move the weekly view.
        MouseArea {
            anchors.fill: parent
            acceptedButtons: Qt.LeftButton
            preventStealing: true
            property real startX: 0
            property real startY: 0
            property bool eligible: false
            property bool tapCandidate: false
            property string startingDisplayWeek: ""
            property string startingWeek: ""
            onPressed: function (mouse) {
                startX = mouse.x;
                startY = mouse.y;
                startingWeek = app.isoDate(app.monday(app.selectedDate));
                startingDisplayWeek = app.isoDate(app.monday(app.displayedDate));
                tapCandidate = true;
                eligible = true;
            }
            onPositionChanged: function (mouse) {
                if (!pressed)
                    return;
                var dx = mouse.x - startX;
                var dy = mouse.y - startY;
                if (Math.abs(dx) > 12 || Math.abs(dy) > 12)
                    tapCandidate = false;
                if (Math.abs(dy) > 24 && Math.abs(dy) >= Math.abs(dx))
                    eligible = false;
            }
            onReleased: function (mouse) {
                var dx = mouse.x - startX;
                var dy = mouse.y - startY;
                var turn = eligible && startingWeek === app.isoDate(app.monday(app.selectedDate)) && Math.abs(dx) >= Math.max(60, weekView.width * 0.10) && Math.abs(dx) > Math.abs(dy) * 2;
                eligible = false;
                if (turn)
                    app.shiftWeek(dx < 0 ? 1 : -1);
                else if (tapCandidate && Math.abs(dx) <= 12 && Math.abs(dy) <= 12 && startingDisplayWeek === app.isoDate(app.monday(app.displayedDate)))
                    app.openWeeklyTap(mouse.x, mouse.y);
                tapCandidate = false;
            }
            onCanceled: {
                eligible = false;
                tapCandidate = false;
            }
        }
    }
}
