import QtQuick

Item {
    id: page
    required property var app
    property alias timeline: schedule.timeline
    CalendarToolbar {
        id: heading
        app: page.app
        view: "day"
    }
    DayView {
        id: schedule
        app: page.app
        anchors.top: heading.bottom
        anchors.bottom: parent.bottom
        width: parent.width
    }
}
