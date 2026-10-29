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
            label: toolbar.view === "month" ? "Previous month" : (toolbar.view === "day" ? "Previous day" : "Previous week")
            onTriggered: toolbar.view === "month" ? app.shiftMonth(-1) : (toolbar.view === "day" ? app.shiftDay(-1) : app.shiftWeek(-1))
        }
        ToolbarButton {
            id: dayButton
            anchors.left: previousButton.right
            icon: "day"
            label: "Day view"
            onTriggered: app.openToolbarDay()
        }
        ToolbarButton {
            id: weekButton
            anchors.left: dayButton.right
            icon: "week"
            label: "Week view"
            onTriggered: {
                if (toolbar.view !== "week")
                    app.showWeek();
            }
        }
        ToolbarButton {
            id: monthButton
            anchors.left: weekButton.right
            icon: "month"
            label: "Month view"
            onTriggered: {
                if (toolbar.view !== "month")
                    app.openMonth();
            }
        }
        ToolbarButton {
            id: todayButton
            anchors.left: monthButton.right
            icon: "today"
            label: "Go to today"
            onTriggered: {
                if (toolbar.view === "month")
                    app.openMonth(new Date());
                else if (toolbar.view === "day")
                    app.loadDay(new Date());
                else
                    app.selectedDate = new Date();
            }
        }
        ToolbarTitle {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Math.max(0, parent.width - 10 * 64 - 24)
            text: toolbar.view === "month" ? Qt.formatDate(app.monthDate, "MMMM yyyy") : toolbar.view === "day" ? Qt.formatDate(app.detailDayDate, "ddd MMM d") : Qt.formatDate(app.dayAt(0), "MMM d") + " – " + Qt.formatDate(app.dayAt(6), "MMM d")
        }
        ToolbarButton {
            anchors.right: syncButton.left
            icon: "add"
            label: "New event"
            enabled: !app.syncBusy
            onTriggered: app.beginEdit(null)
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
            label: toolbar.view === "month" ? "Next month" : (toolbar.view === "day" ? "Next day" : "Next week")
            onTriggered: toolbar.view === "month" ? app.shiftMonth(1) : (toolbar.view === "day" ? app.shiftDay(1) : app.shiftWeek(1))
        }
    }
    Rectangle {
        width: parent.width
        height: 2
        color: "#222222"
    }
}
