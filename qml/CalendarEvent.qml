import QtQuick

Row {
    required property var eventData
    spacing: 8
    Rectangle {
        width: 7
        height: 48
        color: eventData.color
    }
    Column {
        width: parent.width - 15
        Text {
            text: eventData.time
            font.pixelSize: 21
            font.weight: Font.DemiBold
            color: "#000000"
        }
        Text {
            width: parent.width
            text: eventData.title
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 25
            font.weight: Font.DemiBold
            color: "#000000"
        }
    }
}
