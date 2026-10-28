import QtQuick

Rectangle {
    property string label
    signal triggered
    width: 132
    height: 54
    color: "white"
    border.color: "black"
    border.width: 2
    Text {
        anchors.centerIn: parent
        text: parent.label
        textFormat: Text.PlainText
        font.pixelSize: 21
        font.bold: true
        color: "black"
    }
    MouseArea {
        anchors.fill: parent
        onClicked: parent.triggered()
    }
}
