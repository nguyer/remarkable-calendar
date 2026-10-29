import QtQuick

Column {
    id: toolbar
    required property var app
    required property string view
    height: app.toolbarHeight
    width: parent.width
    Item {
        width: 1
        height: 12
    } // Leave the top edge free for AppLoad's pull-down gesture.
    Item {
        width: parent.width
        height: 70
        ToolbarButton {
            id: previousButton
            anchors.left: parent.left
            icon: "previous"
            label: toolbar.view === "day" ? "Previous day" : "Previous week"
            onTriggered: toolbar.view === "day" ? app.shiftDay(-1) : app.shiftWeek(-1)
        }
        ToolbarButton {
            id: viewButton
            anchors.left: previousButton.right
            icon: toolbar.view === "day" ? "week" : "day"
            label: toolbar.view === "day" ? "Week view" : "Day view"
            onTriggered: toolbar.view === "day" ? app.showWeek() : app.openToolbarDay()
        }
        ToolbarButton {
            id: todayButton
            anchors.left: viewButton.right
            icon: "today"
            label: "Go to today"
            onTriggered: {
                if (toolbar.view === "day")
                    app.loadDay(new Date());
                else
                    app.selectedDate = new Date();
            }
        }
        ToolbarButton {
            anchors.left: todayButton.right
            icon: "add"
            label: "New event"
            enabled: !app.syncBusy
            onTriggered: app.beginEdit(null)
        }
        ToolbarTitle {
            anchors.horizontalCenter: parent.horizontalCenter
            text: toolbar.view === "day" ? Qt.formatDate(app.detailDayDate, "ddd MMM d") : Qt.formatDate(app.dayAt(0), "MMM d") + " – " + Qt.formatDate(app.dayAt(6), "MMM d")
        }
        ToolbarButton {
            id: syncButton
            anchors.right: settingsButton.left
            icon: "sync"
            label: app.syncBusy ? "Sync in progress" : "Sync calendars"
            busy: app.syncBusy
            enabled: !app.syncBusy
            onTriggered: app.requestSync(true)
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
        ToolbarButton {
            id: nextButton
            anchors.right: parent.right
            icon: "next"
            label: toolbar.view === "day" ? "Next day" : "Next week"
            onTriggered: toolbar.view === "day" ? app.shiftDay(1) : app.shiftWeek(1)
        }
    }
    Rectangle {
        width: parent.width
        height: 2
        color: "#222222"
    }
}
