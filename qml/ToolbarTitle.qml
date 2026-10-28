import QtQuick

// Shared typography keeps every toolbar title consistent without shrinking text.
Text {
    width: Math.max(0, parent.width - 8 * 64 - 24)
    height: 58
    horizontalAlignment: Text.AlignHCenter
    verticalAlignment: Text.AlignVCenter
    textFormat: Text.PlainText
    font.pixelSize: 26
    font.weight: Font.Bold
    font.capitalization: Font.AllUppercase
    color: "black"
    elide: Text.ElideRight
}
