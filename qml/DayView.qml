import QtQuick

Item {
    required property var app

    property alias timeline: dayList
    component DayGestureArea: MouseArea {
        signal tapped(real x, real y)
        property real startX: 0
        property real startY: 0
        property bool horizontal: true
        property bool tapCandidate: false
        property string pressedDay: ""
        acceptedButtons: Qt.LeftButton
        preventStealing: false
        onPressed: function (mouse) {
            startX = mouse.x;
            startY = mouse.y;
            horizontal = true;
            tapCandidate = true;
            pressedDay = app.isoDate(app.detailDayDate);
        }
        onPositionChanged: function (mouse) {
            if (!pressed)
                return;
            var dx = mouse.x - startX;
            var dy = mouse.y - startY;
            if (Math.abs(dx) > 12 || Math.abs(dy) > 12)
                tapCandidate = false;
            if (Math.abs(dy) > 24 && Math.abs(dy) >= Math.abs(dx))
                horizontal = false;
        }
        onReleased: function (mouse) {
            var dx = mouse.x - startX;
            var dy = mouse.y - startY;
            if (pressedDay !== app.isoDate(app.detailDayDate))
                return;
            if (horizontal && Math.abs(dx) >= Math.max(60, app.width * 0.10) && Math.abs(dx) > Math.abs(dy) * 2)
                app.shiftDay(dx < 0 ? 1 : -1);
            else if (tapCandidate && Math.abs(dx) <= 12 && Math.abs(dy) <= 12)
                tapped(mouse.x, mouse.y);
            tapCandidate = false;
        }
        onCanceled: {
            horizontal = false;
            tapCandidate = false;
        }
    }
    Flickable {
        id: allDayList
        visible: app.detailsLevel === "day"
        anchors.top: parent.top
        width: parent.width
        height: Math.min(200, allDayRows.height)
        contentHeight: allDayRows.height
        clip: true
        interactive: app.displayPrefs.day_scroll
        flickableDirection: Flickable.VerticalFlick
        Column {
            id: allDayRows
            width: parent.width
            Repeater {
                model: app.dayDetailEvents.filter(function (e) {
                    return e.allDay;
                })
                delegate: Item {
                    required property var modelData
                    width: allDayRows.width
                    height: Math.max(64, allDayTitle.implicitHeight + 24)
                    Text {
                        x: 12
                        y: 18
                        text: "All day"
                        font.pixelSize: 20
                        color: "black"
                    }
                    Rectangle {
                        x: 84
                        y: 12
                        width: 7
                        height: parent.height - 24
                        color: modelData.color
                    }
                    Text {
                        id: allDayTitle
                        x: 100
                        y: 12
                        width: parent.width - 118
                        text: modelData.title
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: 26
                        font.bold: true
                        color: "black"
                    }
                    DayGestureArea {
                        anchors.fill: parent
                        onTapped: app.openEvent(modelData, "day")
                    }
                }
            }
        }
    }
    Rectangle {
        id: allDayDivider
        anchors.top: allDayList.bottom
        width: parent.width
        height: app.dayDetailEvents.some(function (e) {
            return e.allDay;
        }) ? 2 : 0
        visible: app.detailsLevel === "day" && height > 0
        color: "#333333"
    }
    Flickable {
        id: dayList
        visible: app.detailsLevel === "day"
        anchors.top: allDayDivider.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        contentHeight: timelineContent.height
        interactive: app.displayPrefs.day_scroll
        flickableDirection: Flickable.VerticalFlick
        Item {
            id: timelineContent
            width: dayList.width
            height: app.displayPrefs.day_scroll ? app.hourHeight * 24 + 80 : dayList.height
            Repeater {
                model: Math.floor((app.dayGeometryState.end - app.dayGeometryState.start) / 60)
                delegate: Item {
                    required property int index
                    y: index * 60 * app.dayGeometryState.scale
                    width: timelineContent.width
                    height: 60 * app.dayGeometryState.scale
                    Text {
                        x: 6
                        y: 2
                        width: 74
                        height: 24
                        fontSizeMode: Text.Fit
                        minimumPixelSize: 14
                        text: app.formatTime(app.minuteTime(app.dayGeometryState.start + index * 60))
                        font.pixelSize: 18
                        font.weight: Font.DemiBold
                        color: "black"
                    }
                    Rectangle {
                        visible: index > 0
                        x: 80
                        width: parent.width - 80
                        height: 1
                        color: "#333333"
                    }
                }
            }
            Repeater {
                model: app.daySchedule
                delegate: Rectangle {
                    required property var modelData
                    x: 84 + modelData.lane * (timelineContent.width - 90) / modelData.lanes
                    y: (modelData.viewStart - app.dayGeometryState.start) * app.dayGeometryState.scale
                    width: Math.max(1, (timelineContent.width - 90) / modelData.lanes - 4)
                    height: (modelData.renderEnd - modelData.viewStart) * app.dayGeometryState.scale
                    color: "white"
                    border.width: 1
                    border.color: "black"
                    clip: true
                    Rectangle {
                        width: 7
                        height: parent.height
                        color: modelData.event.color
                    }
                    Text {
                        x: 14
                        y: 5
                        width: parent.width - 20
                        text: modelData.event.time
                        font.pixelSize: 20
                        font.weight: Font.DemiBold
                        color: "black"
                        elide: Text.ElideRight
                    }
                    Text {
                        x: 14
                        y: 30
                        width: parent.width - 20
                        height: parent.height - 34
                        text: modelData.event.title
                        textFormat: Text.PlainText
                        wrapMode: Text.Wrap
                        font.pixelSize: 24
                        font.bold: true
                        color: "black"
                        clip: true
                    }
                }
            }
            DayGestureArea {
                anchors.fill: parent
                onTapped: function (x, y) {
                    app.openTimelineTap(x, y);
                }
            }
        }
    }
    Rectangle {
        visible: app.detailsLevel === "day" && !!app.dayMessage
        anchors.bottom: parent.bottom
        width: parent.width
        height: dayNotice.implicitHeight + 16
        color: "white"
        Text {
            id: dayNotice
            x: 12
            y: 8
            width: parent.width - 24
            text: app.dayMessage
            wrapMode: Text.Wrap
            font.pixelSize: 22
            color: "black"
        }
    }
}
