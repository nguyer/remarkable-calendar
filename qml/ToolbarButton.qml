import QtQuick

Item {
    id: button
    property string icon
    property string label
    property bool busy: false
    signal triggered
    width: 64
    height: 58
    activeFocusOnTab: enabled
    // The tablet Qt build does not provide the Accessible attached object.
    Keys.onSpacePressed: if (enabled)
        triggered()
    Keys.onReturnPressed: if (enabled)
        triggered()
    Rectangle {
        anchors.fill: parent
        color: "white"
        border.width: button.activeFocus ? 2 : 0
        border.color: "black"
    }
    Canvas {
        id: iconCanvas
        anchors.centerIn: parent
        width: 32
        height: 32
        onPaint: {
            var c = getContext("2d");
            c.reset();
            c.strokeStyle = "#000000";
            c.fillStyle = "#000000";
            c.lineWidth = 2.8;
            c.lineCap = "round";
            c.lineJoin = "round";
            c.beginPath();
            if (button.icon === "previous" || button.icon === "next") {
                var direction = button.icon === "next" ? 1 : -1;
                c.moveTo(16 - direction * 5, 7);
                c.lineTo(16 + direction * 5, 16);
                c.lineTo(16 - direction * 5, 25);
                c.stroke();
            } else if (button.icon === "today") {
                c.rect(5, 7, 22, 21);
                c.moveTo(5, 13);
                c.lineTo(27, 13);
                c.moveTo(11, 4);
                c.lineTo(11, 10);
                c.moveTo(21, 4);
                c.lineTo(21, 10);
                c.stroke();
                c.fillRect(13, 18, 6, 6);
            } else if (button.icon === "add") {
                c.moveTo(16, 5);
                c.lineTo(16, 27);
                c.moveTo(5, 16);
                c.lineTo(27, 16);
                c.stroke();
            } else if (button.icon === "save") {
                c.moveTo(5, 17);
                c.lineTo(12, 24);
                c.lineTo(27, 7);
                c.stroke();
            } else if (button.icon === "edit") {
                c.moveTo(7, 22);
                c.lineTo(23, 6);
                c.lineTo(27, 10);
                c.lineTo(11, 26);
                c.lineTo(5, 28);
                c.closePath();
                c.stroke();
            } else if (button.icon === "delete") {
                c.rect(8, 10, 16, 18);
                c.moveTo(5, 7);
                c.lineTo(27, 7);
                c.moveTo(12, 3);
                c.lineTo(20, 3);
                c.moveTo(13, 14);
                c.lineTo(13, 24);
                c.moveTo(19, 14);
                c.lineTo(19, 24);
                c.stroke();
            } else if (button.icon === "close") {
                c.moveTo(7, 7);
                c.lineTo(25, 25);
                c.moveTo(25, 7);
                c.lineTo(7, 25);
                c.stroke();
            } else if (button.icon === "day") {
                c.rect(5, 5, 22, 23);
                c.moveTo(5, 12);
                c.lineTo(27, 12);
                c.moveTo(11, 18);
                c.lineTo(21, 18);
                c.moveTo(11, 23);
                c.lineTo(21, 23);
                c.stroke();
            } else if (button.icon === "week") {
                c.rect(3, 5, 26, 23);
                c.moveTo(3, 12);
                c.lineTo(29, 12);
                for (var day = 1; day < 7; day++) {
                    var x = 3 + day * 26 / 7;
                    c.moveTo(x, 12);
                    c.lineTo(x, 28);
                }
                c.stroke();
            } else if (button.icon === "settings") {
                c.arc(16, 16, 9, 0, Math.PI * 2);
                c.stroke();
                c.beginPath();
                c.arc(16, 16, 3, 0, Math.PI * 2);
                c.stroke();
                for (var i = 0; i < 8; i++) {
                    var a = i * Math.PI / 4;
                    c.beginPath();
                    c.moveTo(16 + 9 * Math.cos(a), 16 + 9 * Math.sin(a));
                    c.lineTo(16 + 13 * Math.cos(a), 16 + 13 * Math.sin(a));
                    c.stroke();
                }
            } else if (button.icon === "sync") {
                c.arc(16, 16, 10, -Math.PI * 0.85, -Math.PI * 0.05);
                c.stroke();
                c.beginPath();
                c.moveTo(20, 10);
                c.lineTo(26, 14);
                c.lineTo(27, 7);
                c.stroke();
                c.beginPath();
                c.arc(16, 16, 10, Math.PI * 0.15, Math.PI * 0.95);
                c.stroke();
                c.beginPath();
                c.moveTo(12, 22);
                c.lineTo(6, 18);
                c.lineTo(5, 25);
                c.stroke();
                if (button.busy)
                    c.fillRect(13, 13, 6, 6);
            }
        }
        Connections {
            target: button
            function onBusyChanged() {
                iconCanvas.requestPaint();
            }
        }
    }
    MouseArea {
        anchors.fill: parent
        onClicked: button.triggered()
    }
}
