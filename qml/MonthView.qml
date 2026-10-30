import QtQuick

Item {
    id: page
    required property var app
    property alias fontMetrics: monthMetrics
    property var dayLayouts: ({})
    function reflowEvents() {
        if (app.layoutReady && !app.monthPublishing && grid.cellWidth > 0 && grid.rowHeight > 0) {
            var started = Date.now();
            dayLayouts = app.arrangeMonthEvents(app.monthEvents, grid.cellWidth, grid.rowHeight);
            page.app.monthLayoutMs = Date.now() - started;
            console.warn("Calendar month layout: " + app.monthEvents.length + " events, " + (Date.now() - started) + "ms");
        }
    }
    FontMetrics {
        id: monthMetrics
        font.pixelSize: 20
        font.weight: Font.DemiBold
    }
    Connections {
        target: page.app
        function onMonthPublishingChanged() {
            if (!page.app.monthPublishing)
                page.reflowEvents();
        }
        function onMonthEventsChanged() {
            page.reflowEvents();
        }
    }

    readonly property var geometry: app.monthGeometry(app.monthDate)
    readonly property date firstDay: geometry.firstDay
    readonly property date gridStart: geometry.start
    readonly property int rowCount: geometry.rows
    readonly property real weekWidth: 64
    function dateAt(index) {
        var date = new Date(gridStart);
        date.setDate(date.getDate() + index);
        return date;
    }
    function activateCell(x, y) {
        var row = Math.floor(y / grid.rowHeight);
        if (row < 0 || row >= rowCount)
            return;
        if (x < weekWidth)
            app.showWeek(dateAt(row * 7));
        else {
            var column = Math.floor((x - weekWidth) / grid.cellWidth);
            if (column >= 0 && column < 7)
                app.openDate(dateAt(row * 7 + column));
        }
    }
    CalendarToolbar {
        id: heading
        app: page.app
        view: "month"
    }
    Item {
        id: weekdays
        anchors.top: heading.bottom
        width: parent.width
        height: 48
        Text {
            width: page.weekWidth
            height: parent.height
            text: "WK"
            font.pixelSize: 18
            font.bold: true
            color: "black"
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
        }
        Repeater {
            model: page.app.days
            delegate: Text {
                required property int index
                required property string modelData
                x: page.weekWidth + index * (weekdays.width - page.weekWidth) / 7
                width: (weekdays.width - page.weekWidth) / 7
                height: weekdays.height
                text: modelData.toUpperCase()
                font.pixelSize: 22
                font.bold: true
                color: "black"
                horizontalAlignment: Text.AlignHCenter
                verticalAlignment: Text.AlignVCenter
            }
        }
    }
    Item {
        id: grid
        anchors.top: weekdays.bottom
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        readonly property real rowHeight: height / page.rowCount
        readonly property real cellWidth: (width - page.weekWidth) / 7
        onCellWidthChanged: page.reflowEvents()
        onRowHeightChanged: page.reflowEvents()
        Repeater {
            model: page.rowCount
            delegate: Rectangle {
                required property int index
                x: 0
                y: index * grid.rowHeight
                width: page.weekWidth
                height: grid.rowHeight
                color: "#d9d9d9"
                Text {
                    anchors.centerIn: parent
                    text: page.app.isoWeekNumber(page.dateAt(parent.index * 7))
                    font.pixelSize: 25
                    font.bold: true
                    color: "black"
                }
                Rectangle {
                    width: parent.width
                    height: 1
                    color: "#666666"
                }
            }
        }
        Repeater {
            model: page.rowCount * 7
            delegate: Item {
                id: dayCell
                required property int index
                readonly property var eventLayout: page.dayLayouts[page.app.isoDate(date)] || ({
                        entries: [],
                        hidden: 0
                    })
                readonly property date date: page.dateAt(index)
                readonly property bool inMonth: date.getMonth() === page.firstDay.getMonth()
                readonly property bool today: page.app.isoDate(date) === page.app.isoDate(page.app.todayDate)
                x: page.weekWidth + (index % 7) * grid.cellWidth
                y: Math.floor(index / 7) * grid.rowHeight
                width: grid.cellWidth
                height: grid.rowHeight
                Rectangle {
                    width: parent.width
                    height: 1
                    color: "#666666"
                }
                Rectangle {
                    width: 1
                    height: parent.height
                    color: "#666666"
                }
                Rectangle {
                    id: dateBadge
                    x: 1
                    y: 1
                    width: Math.min(64, parent.width - 2)
                    height: width
                    color: parent.today ? page.app.todayHighlight : "transparent"
                    Rectangle {
                        anchors.right: parent.right
                        width: 1
                        height: parent.height
                        color: "#666666"
                    }
                    Rectangle {
                        anchors.bottom: parent.bottom
                        width: parent.width
                        height: 1
                        color: "#666666"
                    }
                    Text {
                        anchors.centerIn: parent
                        text: parent.parent.date.getDate()
                        font.pixelSize: 30
                        font.bold: true
                        color: parent.parent.today ? "white" : (parent.parent.inMonth ? "black" : "#777777")
                    }
                }
            }
        }
        MonthEventsCanvas {
            anchors.fill: parent
            app: page.app
            layouts: page.dayLayouts
            gridStart: page.gridStart
            rowCount: page.rowCount
            weekWidth: page.weekWidth
        }
        MouseArea {
            anchors.fill: parent
            property real startX: 0
            property real startY: 0
            property string pressedMonth: ""
            property bool tapCandidate: false
            preventStealing: true
            onPressed: function (mouse) {
                startX = mouse.x;
                startY = mouse.y;
                tapCandidate = true;
                pressedMonth = page.app.isoDate(page.firstDay);
            }
            onPositionChanged: function (mouse) {
                if (Math.abs(mouse.x - startX) > 12 || Math.abs(mouse.y - startY) > 12)
                    tapCandidate = false;
            }
            onReleased: function (mouse) {
                var dx = mouse.x - startX;
                var dy = mouse.y - startY;
                if (pressedMonth !== page.app.isoDate(page.firstDay))
                    return;
                if (Math.abs(dx) >= Math.max(60, width * 0.10) && Math.abs(dx) > 2 * Math.abs(dy))
                    page.app.shiftMonth(dx < 0 ? 1 : -1);
                else if (tapCandidate && Math.abs(dx) <= 12 && Math.abs(dy) <= 12)
                    page.activateCell(mouse.x, mouse.y);
                tapCandidate = false;
            }
            onCanceled: tapCandidate = false
        }
    }
    Rectangle {
        anchors.bottom: parent.bottom
        width: parent.width
        height: monthNotice.implicitHeight + 16
        color: "white"
        visible: !!page.app.monthMessage
        Text {
            id: monthNotice
            x: 8
            y: 8
            width: parent.width - 16
            text: page.app.monthMessage
            wrapMode: Text.Wrap
            font.pixelSize: 20
            color: "black"
        }
    }
}
