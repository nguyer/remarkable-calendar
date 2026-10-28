import QtQuick

Rectangle {
    id: detailsPage
    required property var app
    property alias timeline: dayView.timeline
    property alias eventScroll: eventView
    anchors.fill: parent
    z: 20
    visible: app.detailsLevel !== ""
    color: "white"
    MouseArea {
        anchors.fill: parent
    }
    Item {
        id: detailsHeader
        width: parent.width
        height: app.toolbarHeight
        ToolbarButton {
            id: previousDayButton
            y: 12
            visible: app.detailsLevel === "day"
            anchors.left: parent.left
            icon: "previous"
            label: "Previous day"
            onTriggered: app.shiftDay(-1)
        }
        ToolbarButton {
            id: weekViewButton
            y: 12
            visible: app.detailsLevel === "day"
            anchors.left: previousDayButton.right
            icon: "week"
            label: "Week view"
            onTriggered: app.showWeek()
        }
        ToolbarButton {
            id: todayDayButton
            y: 12
            visible: app.detailsLevel === "day"
            anchors.left: weekViewButton.right
            icon: "today"
            label: "Today"
            onTriggered: app.loadDay(new Date())
        }
        ToolbarButton {
            y: 12
            visible: app.detailsLevel === "day"
            anchors.left: todayDayButton.right
            icon: "add"
            label: "New event"
            enabled: !app.syncBusy
            onTriggered: app.beginEdit(null)
        }
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
            text: app.detailsLevel === "day" ? Qt.formatDate(app.detailDayDate, "ddd MMM d") : "Event details"
        }
        ToolbarButton {
            id: nextDayButton
            y: 12
            visible: app.detailsLevel === "day"
            anchors.right: parent.right
            icon: "next"
            label: "Next day"
            onTriggered: app.shiftDay(1)
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
    DayView {
        id: dayView
        app: detailsPage.app
        anchors.top: detailsHeader.bottom
        anchors.bottom: parent.bottom
        width: parent.width
    }
    EventView {
        id: eventView
        app: detailsPage.app
        anchors.top: detailsHeader.bottom
        anchors.bottom: parent.bottom
    }
}
