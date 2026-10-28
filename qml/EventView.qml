import QtQuick

Flickable {
    id: eventDetailsScroll
    required property var app
    visible: app.detailsLevel === "event"
    anchors.top: parent.top
    anchors.bottom: parent.bottom
    x: 18
    width: parent.width - 36
    clip: true
    contentHeight: eventDetailBody.height + 36
    Column {
        id: eventDetailBody
        y: 18
        width: parent.width
        spacing: 20
        property var event: app.activeDetailEvent
        property var info: event && event.details ? event.details : null
        Rectangle {
            width: parent.width
            height: 7
            color: eventDetailBody.event ? eventDetailBody.event.color : "black"
        }
        Text {
            visible: !!eventDetailBody.info && eventDetailBody.info.pending
            width: parent.width
            text: "Saved on tablet · pending Google sync" + (eventDetailBody.info && eventDetailBody.info.sync_error ? "\n" + eventDetailBody.info.sync_error : "")
            wrapMode: Text.Wrap
            font.pixelSize: 24
            font.bold: true
            color: "black"
        }
        Text {
            width: parent.width
            text: eventDetailBody.event ? eventDetailBody.event.title : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 40
            font.bold: true
            color: "black"
        }
        Text {
            width: parent.width
            text: app.eventSpan(eventDetailBody.event)
            wrapMode: Text.Wrap
            font.pixelSize: 32
            font.weight: Font.DemiBold
            color: "black"
        }
        Text {
            width: parent.width
            text: eventDetailBody.info ? eventDetailBody.info.calendar_name + (eventDetailBody.info.timezone ? " · " + eventDetailBody.info.timezone : "") : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 28
            color: "black"
        }
        Text {
            visible: !!eventDetailBody.info && !!eventDetailBody.info.location
            text: "Location"
            font.pixelSize: 30
            font.bold: true
            color: "black"
        }
        Text {
            visible: !!eventDetailBody.info && !!eventDetailBody.info.location
            width: parent.width
            text: eventDetailBody.info ? eventDetailBody.info.location : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 32
            color: "black"
        }
        Text {
            visible: !!eventDetailBody.info && !!eventDetailBody.info.description
            text: "Description"
            font.pixelSize: 30
            font.bold: true
            color: "black"
        }
        Text {
            visible: !!eventDetailBody.info && !!eventDetailBody.info.description
            width: parent.width
            text: eventDetailBody.info ? app.plainDescription(eventDetailBody.info.description) : ""
            textFormat: Text.PlainText
            wrapMode: Text.Wrap
            font.pixelSize: 32
            color: "black"
        }
        Text {
            visible: !eventDetailBody.info || (!eventDetailBody.info.location && !eventDetailBody.info.description)
            width: parent.width
            text: "No location or description."
            wrapMode: Text.Wrap
            font.pixelSize: 28
            color: "black"
        }
    }
}
